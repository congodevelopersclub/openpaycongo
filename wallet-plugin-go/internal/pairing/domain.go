package pairing

import (
	"errors"
	"time"
)

const (
	ProtocolVersion                         = "1"
	AlgorithmSuite                          = "X25519-HKDF-SHA256-AES-256-GCM+Ed25519"
	PairingIntentIDSize                     = 16
	CompletionReservationIDSize             = 16
	SecretSize                              = 32
	SignatureSize                           = 64
	EndpointLengthMax                       = 512
	IdentifierLengthMax                     = 128
	AdminSubjectLengthMax                   = 256
	EnrollmentTTLMin                        = 30 * time.Second
	EnrollmentTTLMax                        = 5 * time.Minute
	EnrollmentAttemptsMax            uint8  = 5
	CompletionReservationsMax        uint8  = 8
	InstallIDLengthMax                      = 128
	CompletionCiphertextMax                 = 2048
	SessionKeySize                          = 32
	ShortAuthenticationCandidateSize        = 4
	ShortAuthenticationCandidates           = 4
	NonceSize                               = 12
	ProtectedMaterialSizeMax                = 1024
	ProtectionAADSizeMax                    = 1024
	ProtectedKeyIDLengthMax                 = 64
	ProtectedNonceSizeMax                   = 32
	CleanupPageSizeMax               uint16 = 100
	TranscriptSizeMax                       = 4096
	FailureCleanupTimeout                   = 2 * time.Second
)

var (
	ErrEnrollmentUnavailable       = errors.New("enrollment unavailable")
	ErrInvalidConfiguration        = errors.New("invalid pairing configuration")
	ErrInvalidTenantID             = errors.New("invalid tenant ID")
	ErrInvalidCompletion           = errors.New("invalid enrollment completion")
	ErrInvalidPairingQR            = errors.New("invalid pairing QR")
	ErrInvalidProtectedMaterial    = errors.New("invalid protected material")
	ErrInvalidProtectionAAD        = errors.New("invalid protection associated data")
	ErrInvalidCleanupLimit         = errors.New("invalid cleanup limit")
	ErrInvalidAdminPrincipal       = errors.New("invalid verified admin principal")
	ErrInvalidConfirmation         = errors.New("invalid pairing confirmation")
	ErrIntentCollision             = errors.New("pairing intent collision")
	ErrIdentitySignerInconsistent  = errors.New("identity signer public key and signature mismatch")
	ErrCompletionCleanupFailed     = errors.New("pairing completion cleanup failed")
	ErrKeyProtectionFailure        = errors.New("pairing key protection failure")
	ErrKeyProtectorRetryable       = errors.New("pairing key protector dependency unavailable")
	ErrKeyProtectorIntegrity       = errors.New("pairing protected material integrity failure")
	ErrConfirmationConflict        = errors.New("pairing confirmation conflict")
	ErrUntrustedEnrollmentIdentity = errors.New("untrusted enrollment identity")
)

type PairingIntentID [PairingIntentIDSize]byte
type CompletionReservationID [CompletionReservationIDSize]byte
type IntentNonce [SecretSize]byte
type ServerKeyAgreementPublic [SecretSize]byte
type EnrollmentSigningFingerprint [SecretSize]byte
type EnrollmentSigningPublicKey [SecretSize]byte
type DeviceSigningPublicKey [SecretSize]byte
type Signature [SignatureSize]byte
type ClientKeyAgreementPublic [SecretSize]byte
type DeviceID [PairingIntentIDSize]byte
type Nonce [NonceSize]byte
type RequestDigest [SecretSize]byte
type ConfirmationRequestID [PairingIntentIDSize]byte
type SecretMaterial [SecretSize]byte
type PairingStatusToken [SecretSize]byte
type PairingStatusTokenDigest [SecretSize]byte
type SessionKey [SessionKeySize]byte
type ShortAuthenticationCode [6]byte
type DeviceProofTranscript struct {
	value  [TranscriptSizeMax]byte
	length uint16
}

func newDeviceProofTranscript(value []byte) DeviceProofTranscript {
	if len(value) == 0 || len(value) > TranscriptSizeMax {
		panic("pairing: invalid device proof transcript bound")
	}
	var transcript DeviceProofTranscript
	copy(transcript.value[:], value)
	transcript.length = uint16(len(value))
	return transcript
}

func (transcript DeviceProofTranscript) Bytes() []byte {
	return transcript.value[:transcript.length]
}

func (code ShortAuthenticationCode) String() string { return string(code[:]) }

type EnrollmentTrustMode string

const (
	EnrollmentTrustFirstUseRequiresSAS EnrollmentTrustMode = "first_use_requires_sas"
	EnrollmentTrustPinnedContinuity    EnrollmentTrustMode = "pinned_continuity"
)

type EnrollmentPinState uint8

const (
	EnrollmentPinAbsent EnrollmentPinState = iota + 1
	EnrollmentPinMatches
	EnrollmentPinDiffers
)

type LocalRecoveryAuthorization struct{ authenticated bool }

func NewLocalRecoveryAuthorization(authenticated bool) (LocalRecoveryAuthorization, error) {
	if !authenticated {
		return LocalRecoveryAuthorization{}, ErrUntrustedEnrollmentIdentity
	}
	return LocalRecoveryAuthorization{authenticated: true}, nil
}

type ProtectedMaterial struct {
	value []byte
}

func NewProtectedMaterial(value []byte) (ProtectedMaterial, error) {
	if len(value) == 0 || len(value) > ProtectedMaterialSizeMax {
		return ProtectedMaterial{}, ErrInvalidProtectedMaterial
	}
	return ProtectedMaterial{value: append([]byte(nil), value...)}, nil
}

func (material ProtectedMaterial) Bytes() []byte {
	return append([]byte(nil), material.value...)
}

func (material ProtectedMaterial) IsZero() bool {
	return len(material.value) == 0
}

type ProtectionAAD struct {
	value []byte
}

func NewProtectionAAD(value []byte) (ProtectionAAD, error) {
	if len(value) == 0 || len(value) > ProtectionAADSizeMax {
		return ProtectionAAD{}, ErrInvalidProtectionAAD
	}
	return ProtectionAAD{value: append([]byte(nil), value...)}, nil
}

func (aad ProtectionAAD) Bytes() []byte {
	return append([]byte(nil), aad.value...)
}

type TenantID struct {
	value string
}

func ParseTenantID(value string) (TenantID, error) {
	if !isPortableIdentifier(value, IdentifierLengthMax) {
		return TenantID{}, ErrInvalidTenantID
	}
	return TenantID{value: value}, nil
}

func (id TenantID) String() string {
	return id.value
}

func isPortableIdentifier(value string, maximumLength int) bool {
	if len(value) == 0 || len(value) > maximumLength {
		return false
	}
	for index := 0; index < len(value); index++ {
		character := value[index]
		isLetter := character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z'
		isDigit := character >= '0' && character <= '9'
		isSeparator := character == '-' || character == '_' || character == '.' || character == ':'
		if !isLetter && !isDigit && !isSeparator {
			return false
		}
	}
	return true
}

type PairingQR struct {
	Algorithms                   string
	Endpoint                     string
	EnrollmentSigningFingerprint EnrollmentSigningFingerprint
	EnrollmentSigningPublicKey   EnrollmentSigningPublicKey
	IntentID                     PairingIntentID
	IntentNonce                  IntentNonce
	ExpiresAt                    time.Time
	ServerKeyAgreementPublic     ServerKeyAgreementPublic
	Signature                    Signature
	TrustMode                    EnrollmentTrustMode
	Version                      string
}

type PendingEnrollment struct {
	InvalidProofAttempts         uint8
	ExpiresAt                    time.Time
	ID                           PairingIntentID
	IntentNonce                  IntentNonce
	ProtectedServerPrivateKey    ProtectedMaterial
	EnrollmentSigningFingerprint EnrollmentSigningFingerprint
	ServerKeyAgreementPublic     ServerKeyAgreementPublic
	TenantID                     TenantID
	TrustMode                    EnrollmentTrustMode
}

type CompletionReservation struct {
	Enrollment PendingEnrollment
	ID         CompletionReservationID
}

type CompletionRequest struct {
	Ciphertext               []byte
	ClientKeyAgreementPublic ClientKeyAgreementPublic
	IntentID                 PairingIntentID
	Nonce                    Nonce
	Version                  string
}

type CompletionStatus string

const (
	CompletionPendingConfirmation CompletionStatus = "pending_confirmation"
	CompletionReplayed            CompletionStatus = "replayed"
)

type CompletionResult struct {
	Ciphertext []byte
	DeviceID   DeviceID
	Nonce      Nonce
	Status     CompletionStatus
}

type DeviceRecord struct {
	ActivationStatus         DeviceActivationStatus
	DeviceSigningPublicKey   DeviceSigningPublicKey
	ID                       DeviceID
	InstallID                string
	ProtectedInstallRoot     ProtectedMaterial
	PairingStatusTokenDigest PairingStatusTokenDigest
	ShortAuthenticationCode  ShortAuthenticationCode
	TenantID                 TenantID
}

type PhonePairingStatusView struct {
	Status DeviceActivationStatus
}

type DeviceActivationStatus string

const (
	DeviceActive              DeviceActivationStatus = "active"
	DevicePendingConfirmation DeviceActivationStatus = "pending_confirmation"
	DeviceRevoked             DeviceActivationStatus = "revoked"
	DeviceExpired             DeviceActivationStatus = "expired"
)

type ConfirmationDecision uint8

const (
	ConfirmationCodesMatch ConfirmationDecision = iota + 1
	ConfirmationCodesMismatch
)

type ConfirmationReason string

const (
	ConfirmationReasonCodesComparedMatch    ConfirmationReason = "codes_compared_match"
	ConfirmationReasonCodesComparedMismatch ConfirmationReason = "codes_compared_mismatch"
)

type VerifiedAdminPrincipal struct {
	subject  string
	tenantID TenantID
}

func NewVerifiedAdminPrincipal(subject string, tenantID TenantID) (VerifiedAdminPrincipal, error) {
	if tenantID.value == "" || !isBoundedPrintableASCII(subject, AdminSubjectLengthMax) {
		return VerifiedAdminPrincipal{}, ErrInvalidAdminPrincipal
	}
	return VerifiedAdminPrincipal{subject: subject, tenantID: tenantID}, nil
}

func (principal VerifiedAdminPrincipal) Subject() string {
	return principal.subject
}

func (principal VerifiedAdminPrincipal) TenantID() TenantID {
	return principal.tenantID
}

func isBoundedPrintableASCII(value string, maximumLength int) bool {
	if len(value) == 0 || len(value) > maximumLength {
		return false
	}
	for index := 0; index < len(value); index++ {
		if value[index] < 0x21 || value[index] > 0x7e {
			return false
		}
	}
	return true
}

type ConfirmationCommand struct {
	Actor       VerifiedAdminPrincipal
	ConfirmedAt time.Time
	Decision    ConfirmationDecision
	IntentID    PairingIntentID
	Reason      ConfirmationReason
	RequestID   ConfirmationRequestID
}

type PairingConfirmationView struct {
	ExpiresAt                       time.Time
	ShortAuthenticationCode         ShortAuthenticationCode
	IncludesShortAuthenticationCode bool
	Status                          DeviceActivationStatus
}

type CompletionCommit struct {
	CompletedAt   time.Time
	Device        DeviceRecord
	IntentID      PairingIntentID
	MaxAttempts   uint8
	ReservationID CompletionReservationID
	RequestDigest RequestDigest
	Result        CompletionResult
}

type CommitState uint8

const (
	CommitNotCommitted CommitState = iota + 1
	CommitCommitted
	CommitUnknown
)

type CommitOutcome struct {
	State  CommitState
	Result CompletionResult
}
