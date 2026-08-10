package pairing

import (
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/sha256"
	"errors"
	"io"
	"net"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const timeFormat = "2006-01-02T15:04:05Z"

type Service struct {
	clock         Clock
	endpoint      string
	enrollmentTTL time.Duration
	identity      IdentitySigner
	keyProtector  KeyProtector
	maxAttempts   uint8
	random        io.Reader
	repository    Repository
	trustMode     EnrollmentTrustMode
}

func NewService(options ServiceOptions) (*Service, error) {
	if err := validateOptions(options); err != nil {
		return nil, err
	}
	return &Service{
		clock:         options.Clock,
		endpoint:      options.Endpoint,
		enrollmentTTL: options.EnrollmentTTL,
		identity:      options.Identity,
		keyProtector:  options.KeyProtector,
		maxAttempts:   options.MaxAttempts,
		random:        options.Random,
		repository:    options.Repository,
		trustMode:     options.TrustMode,
	}, nil
}

func (service *Service) IssueEnrollment(
	ctx context.Context,
	tenantID TenantID,
) (PairingQR, error) {
	if tenantID.value == "" {
		return PairingQR{}, ErrInvalidTenantID
	}

	material, err := service.issueMaterial()
	if err != nil {
		return PairingQR{}, err
	}
	now := service.clock.Now().UTC().Truncate(time.Second)
	qr := service.issueQR(material, now)

	var serverPrivateKey SecretMaterial
	copy(serverPrivateKey[:], material.serverPrivateKey.Bytes())
	protectedPrivateKey, err := service.keyProtector.Protect(
		ctx,
		serverPrivateKey,
		keyProtectionAAD("intent-private", tenantID, material.intentID[:]),
	)
	wipe(serverPrivateKey[:])
	if err != nil {
		return PairingQR{}, err
	}
	if protectedPrivateKey.IsZero() {
		return PairingQR{}, ErrInvalidProtectedMaterial
	}
	record := PendingEnrollment{
		ExpiresAt:                    qr.ExpiresAt,
		ID:                           material.intentID,
		IntentNonce:                  qr.IntentNonce,
		ProtectedServerPrivateKey:    protectedPrivateKey,
		EnrollmentSigningFingerprint: qr.EnrollmentSigningFingerprint,
		ServerKeyAgreementPublic:     qr.ServerKeyAgreementPublic,
		TenantID:                     tenantID,
		TrustMode:                    qr.TrustMode,
	}
	signature, err := service.identity.Sign(qrSigningTranscript(qr))
	if err != nil {
		return PairingQR{}, err
	}
	qr.Signature = signature
	if !ed25519.Verify(
		ed25519.PublicKey(qr.EnrollmentSigningPublicKey[:]),
		qrSigningTranscript(qr),
		qr.Signature[:],
	) {
		return PairingQR{}, ErrIdentitySignerInconsistent
	}
	if err := service.repository.Create(ctx, record); err != nil {
		return PairingQR{}, err
	}
	return qr, nil
}

func (service *Service) CompleteEnrollment(
	ctx context.Context,
	request CompletionRequest,
) (CompletionResult, error) {
	if request.Version != ProtocolVersion {
		return CompletionResult{}, ErrEnrollmentUnavailable
	}
	requestDigest, err := completionRequestDigest(request)
	if err != nil {
		return CompletionResult{}, ErrEnrollmentUnavailable
	}
	replay, found, err := service.repository.FindCompletion(
		ctx,
		request.IntentID,
		requestDigest,
	)
	if err != nil {
		return CompletionResult{}, ErrEnrollmentUnavailable
	}
	if found {
		replay.Status = CompletionReplayed
		return replay, nil
	}

	reservation, err := service.repository.BeginCompletionAttempt(
		ctx,
		request.IntentID,
		service.clock.Now().UTC(),
		service.maxAttempts,
		CompletionReservationsMax,
	)
	if err != nil {
		return CompletionResult{}, ErrEnrollmentUnavailable
	}
	record := reservation.Enrollment
	proof, sessionKeys, err := service.openCompletionProof(ctx, record, request)
	if err != nil {
		if errors.Is(err, ErrKeyProtectorRetryable) {
			return CompletionResult{}, service.releaseCompletionAttempt(ctx, request.IntentID, reservation.ID)
		}
		if errors.Is(err, ErrKeyProtectionFailure) {
			return CompletionResult{}, service.abortCompletion(ctx, request.IntentID)
		}
		cleanupContext, cancel := service.failureCleanupContext(ctx)
		defer cancel()
		if cleanupErr := service.repository.FinishFailedCompletion(
			cleanupContext,
			request.IntentID,
			reservation.ID,
			service.clock.Now().UTC(),
			service.maxAttempts,
		); cleanupErr != nil {
			return CompletionResult{}, errors.Join(ErrEnrollmentUnavailable, ErrCompletionCleanupFailed)
		}
		return CompletionResult{}, ErrEnrollmentUnavailable
	}
	result, device, err := service.prepareCompletion(ctx, record, proof, sessionKeys)
	if err != nil {
		if errors.Is(err, ErrKeyProtectorRetryable) {
			return CompletionResult{}, service.releaseCompletionAttempt(ctx, request.IntentID, reservation.ID)
		}
		return CompletionResult{}, service.abortCompletion(ctx, request.IntentID)
	}
	commit := CompletionCommit{
		CompletedAt:   service.clock.Now().UTC(),
		Device:        device,
		IntentID:      request.IntentID,
		MaxAttempts:   service.maxAttempts,
		ReservationID: reservation.ID,
		RequestDigest: requestDigest,
		Result:        result,
	}
	outcome, err := service.repository.Commit(ctx, commit)
	if outcome.State == CommitCommitted {
		return outcome.Result, nil
	}
	if outcome.State == CommitUnknown {
		reconcileContext, cancel := service.failureCleanupContext(ctx)
		defer cancel()
		reconciled, found, reconcileErr := service.repository.FindCompletion(reconcileContext, request.IntentID, requestDigest)
		if reconcileErr == nil && found {
			return reconciled, nil
		}
		return CompletionResult{}, ErrEnrollmentUnavailable
	}
	if err != nil || outcome.State == CommitNotCommitted {
		return CompletionResult{}, service.abortCompletion(ctx, request.IntentID)
	}
	return CompletionResult{}, ErrEnrollmentUnavailable
}

func (service *Service) releaseCompletionAttempt(
	ctx context.Context,
	intentID PairingIntentID,
	reservationID CompletionReservationID,
) error {
	releaseContext, cancel := service.failureCleanupContext(ctx)
	defer cancel()
	if err := service.repository.ReleaseCompletionAttempt(releaseContext, intentID, reservationID); err != nil {
		return errors.Join(ErrEnrollmentUnavailable, ErrCompletionCleanupFailed)
	}
	return ErrEnrollmentUnavailable
}

func (service *Service) failureCleanupContext(ctx context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.WithoutCancel(ctx), FailureCleanupTimeout)
}

func (service *Service) abortCompletion(ctx context.Context, intentID PairingIntentID) error {
	cleanupContext, cancel := service.failureCleanupContext(ctx)
	defer cancel()
	if err := service.repository.AbortCompletion(
		cleanupContext,
		intentID,
		service.clock.Now().UTC(),
	); err != nil {
		return errors.Join(ErrEnrollmentUnavailable, ErrCompletionCleanupFailed)
	}
	return ErrEnrollmentUnavailable
}

func (service *Service) ConfirmPairing(
	ctx context.Context,
	actor VerifiedAdminPrincipal,
	intentID PairingIntentID,
	requestID ConfirmationRequestID,
	decision ConfirmationDecision,
	reason ConfirmationReason,
) (DeviceActivationStatus, error) {
	if actor.subject == "" || actor.tenantID.value == "" || requestID == (ConfirmationRequestID{}) {
		return "", ErrInvalidConfirmation
	}
	validMatch := decision == ConfirmationCodesMatch && reason == ConfirmationReasonCodesComparedMatch
	validMismatch := decision == ConfirmationCodesMismatch && reason == ConfirmationReasonCodesComparedMismatch
	if !validMatch && !validMismatch {
		return "", ErrInvalidConfirmation
	}
	command := ConfirmationCommand{
		Actor:       actor,
		ConfirmedAt: service.clock.Now().UTC(),
		Decision:    decision,
		IntentID:    intentID,
		Reason:      reason,
		RequestID:   requestID,
	}
	status, err := service.repository.Confirm(ctx, command)
	if err != nil {
		if errors.Is(err, ErrConfirmationConflict) {
			return "", ErrConfirmationConflict
		}
		return "", ErrEnrollmentUnavailable
	}
	return status, nil
}

func (service *Service) GetPairingConfirmation(
	ctx context.Context,
	actor VerifiedAdminPrincipal,
	intentID PairingIntentID,
) (PairingConfirmationView, error) {
	if actor.subject == "" || actor.tenantID.value == "" {
		return PairingConfirmationView{}, ErrEnrollmentUnavailable
	}
	view, err := service.repository.GetConfirmation(
		ctx,
		actor,
		intentID,
		service.clock.Now().UTC(),
	)
	if err != nil {
		return PairingConfirmationView{}, ErrEnrollmentUnavailable
	}
	return view, nil
}

func (service *Service) GetPhonePairingStatus(
	ctx context.Context,
	token PairingStatusToken,
) (PhonePairingStatusView, error) {
	if token == (PairingStatusToken{}) {
		return PhonePairingStatusView{}, ErrEnrollmentUnavailable
	}
	digest := sha256.Sum256(token[:])
	view, err := service.repository.GetPhoneStatus(ctx, digest)
	if err != nil {
		return PhonePairingStatusView{}, ErrEnrollmentUnavailable
	}
	return view, nil
}

func (service *Service) AcknowledgePhonePairingStatus(
	ctx context.Context,
	token PairingStatusToken,
	status DeviceActivationStatus,
) error {
	if token == (PairingStatusToken{}) || (status != DeviceActive && status != DeviceRevoked && status != DeviceExpired) {
		return ErrEnrollmentUnavailable
	}
	digest := sha256.Sum256(token[:])
	if err := service.repository.AcknowledgePhoneStatus(ctx, digest, status, service.clock.Now().UTC()); err != nil {
		return ErrEnrollmentUnavailable
	}
	return nil
}

func (service *Service) CleanupExpiredEnrollments(
	ctx context.Context,
	limit uint16,
) (uint16, error) {
	if limit == 0 || limit > CleanupPageSizeMax {
		return 0, ErrInvalidCleanupLimit
	}
	return service.repository.CleanupExpired(ctx, service.clock.Now().UTC(), limit)
}

type issueMaterial struct {
	intentID         PairingIntentID
	intentNonce      IntentNonce
	serverPrivateKey *ecdh.PrivateKey
}

func (service *Service) issueMaterial() (issueMaterial, error) {
	var material issueMaterial
	if _, err := io.ReadFull(service.random, material.intentID[:]); err != nil {
		return issueMaterial{}, err
	}
	if _, err := io.ReadFull(service.random, material.intentNonce[:]); err != nil {
		return issueMaterial{}, err
	}
	privateKey, err := ecdh.X25519().GenerateKey(service.random)
	if err != nil {
		return issueMaterial{}, err
	}
	material.serverPrivateKey = privateKey
	return material, nil
}

func (service *Service) issueQR(material issueMaterial, now time.Time) PairingQR {
	identityPublicKey := service.identity.PublicKey()
	if len(identityPublicKey) != ed25519.PublicKeySize {
		panic("pairing: identity signer returned invalid public key")
	}
	enrollmentSigningFingerprint := sha256.Sum256(identityPublicKey)
	serverPublicKeyBytes := material.serverPrivateKey.PublicKey().Bytes()
	if len(serverPublicKeyBytes) != SecretSize {
		panic("pairing: X25519 public key has invalid size")
	}

	var identityPublicKeyFixed EnrollmentSigningPublicKey
	copy(identityPublicKeyFixed[:], identityPublicKey)
	var serverPublicKey ServerKeyAgreementPublic
	copy(serverPublicKey[:], serverPublicKeyBytes)
	return PairingQR{
		Algorithms:                   AlgorithmSuite,
		Endpoint:                     service.endpoint,
		EnrollmentSigningFingerprint: enrollmentSigningFingerprint,
		EnrollmentSigningPublicKey:   identityPublicKeyFixed,
		IntentID:                     material.intentID,
		IntentNonce:                  material.intentNonce,
		ExpiresAt:                    now.Add(service.enrollmentTTL),
		ServerKeyAgreementPublic:     serverPublicKey,
		TrustMode:                    service.trustMode,
		Version:                      ProtocolVersion,
	}
}

func validateOptions(options ServiceOptions) error {
	if options.Clock == nil || options.Identity == nil {
		return ErrInvalidConfiguration
	}
	if options.KeyProtector == nil || options.Random == nil || options.Repository == nil {
		return ErrInvalidConfiguration
	}
	if options.EnrollmentTTL < EnrollmentTTLMin || options.EnrollmentTTL > EnrollmentTTLMax {
		return ErrInvalidConfiguration
	}
	if options.MaxAttempts == 0 || options.MaxAttempts > EnrollmentAttemptsMax {
		return ErrInvalidConfiguration
	}
	if options.TrustMode != EnrollmentTrustFirstUseRequiresSAS && options.TrustMode != EnrollmentTrustPinnedContinuity {
		return ErrInvalidConfiguration
	}
	if err := validateEndpoint(options.Endpoint); err != nil {
		return errors.Join(ErrInvalidConfiguration, err)
	}
	return nil
}

func validateEndpoint(endpoint string) error {
	if len(endpoint) == 0 || len(endpoint) > EndpointLengthMax {
		return ErrInvalidConfiguration
	}
	if !strings.HasPrefix(endpoint, "https://") {
		return ErrInvalidConfiguration
	}
	parsedURL, err := url.Parse(endpoint)
	if err != nil {
		return err
	}
	if parsedURL.Scheme != "https" || parsedURL.Host == "" || parsedURL.Opaque != "" {
		return ErrInvalidConfiguration
	}
	if parsedURL.User != nil || parsedURL.Fragment != "" || parsedURL.RawQuery != "" {
		return ErrInvalidConfiguration
	}
	if parsedURL.Path != "/v1/pairing/complete" || parsedURL.RawPath != "" {
		return ErrInvalidConfiguration
	}
	hostname := parsedURL.Hostname()
	if hostname == "" || hostname != strings.ToLower(hostname) || net.ParseIP(hostname) != nil {
		return ErrInvalidConfiguration
	}
	labels := strings.Split(hostname, ".")
	if len(labels) < 2 {
		return ErrInvalidConfiguration
	}
	for _, label := range labels {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return ErrInvalidConfiguration
		}
		for index := range len(label) {
			character := label[index]
			if !((character >= 'a' && character <= 'z') ||
				(character >= '0' && character <= '9') || character == '-') {
				return ErrInvalidConfiguration
			}
		}
	}
	if port := parsedURL.Port(); port != "" {
		portNumber, portErr := strconv.ParseUint(port, 10, 16)
		if portErr != nil || portNumber == 0 || strconv.FormatUint(portNumber, 10) != port {
			return ErrInvalidConfiguration
		}
	}
	return nil
}
