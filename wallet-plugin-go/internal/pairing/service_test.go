package pairing

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"testing"
	"time"
)

func TestPortableIdentifiersRejectCrossDatabaseAmbiguity(t *testing.T) {
	t.Parallel()

	for _, value := range []string{"", "tenant/other", "tenant\x00other", "ténant"} {
		if isPortableIdentifier(value, IdentifierLengthMax) {
			t.Fatalf("identifier %q was accepted", value)
		}
	}
	for _, value := range []string{"tenant-demo", "tenant_demo", "tenant.example:1"} {
		if !isPortableIdentifier(value, IdentifierLengthMax) {
			t.Fatalf("identifier %q was rejected", value)
		}
	}
}

func TestPairingEndpointUsesOneCanonicalGrammar(t *testing.T) {
	t.Parallel()

	valid := []string{
		"https://pairing.example.test/v1/pairing/complete",
		"https://pairing.example.test:8443/v1/pairing/complete",
	}
	for _, endpoint := range valid {
		if err := validateEndpoint(endpoint); err != nil {
			t.Fatalf("canonical endpoint %q: %v", endpoint, err)
		}
	}
	invalid := []string{
		"https://PAIRING.example.test/v1/pairing/complete",
		"https://pairing.example.test/v1/pairing/complete/",
		"https://pairing.example.test/other",
		"https://pairing.example.test:08443/v1/pairing/complete",
		"https://pairing.example.test:65536/v1/pairing/complete",
		"https://127.0.0.1/v1/pairing/complete",
		"https://pairing..example.test/v1/pairing/complete",
		"https://pairing.example.test/v1/pairing/%63omplete",
	}
	for _, endpoint := range invalid {
		if err := validateEndpoint(endpoint); err == nil {
			t.Fatalf("non-canonical endpoint %q accepted", endpoint)
		}
	}
}

func TestKeyProtectorConformanceRejectsWrongAADAndTampering(t *testing.T) {
	t.Parallel()

	protector := &authenticatedTestKeyProtector{}
	var secret SecretMaterial
	copy(secret[:], bytes.Repeat([]byte{0x5a}, SecretSize))
	aad, err := NewProtectionAAD([]byte("tenant-a/purpose"))
	if err != nil {
		t.Fatalf("create protection AAD: %v", err)
	}
	protected, err := protector.Protect(context.Background(), secret, aad)
	if err != nil {
		t.Fatalf("protect secret: %v", err)
	}
	if bytes.Equal(protected.Bytes(), secret[:]) {
		t.Fatal("protected representation exposed plaintext")
	}
	protectedAgain, err := protector.Protect(context.Background(), secret, aad)
	if err != nil {
		t.Fatalf("protect repeated secret: %v", err)
	}
	if bytes.Equal(protected.Bytes(), protectedAgain.Bytes()) {
		t.Fatal("repeated protection reused an AEAD nonce")
	}
	wrongAAD, err := NewProtectionAAD([]byte("tenant-b/purpose"))
	if err != nil {
		t.Fatalf("create wrong protection AAD: %v", err)
	}
	if _, err := protector.Unprotect(
		context.Background(),
		protected,
		wrongAAD,
	); err == nil {
		t.Fatal("wrong associated data was accepted")
	}
	tamperedBytes := protected.Bytes()
	tamperedBytes[len(tamperedBytes)-1] ^= 0x01
	tampered, err := NewProtectedMaterial(tamperedBytes)
	if err != nil {
		t.Fatalf("create tampered protected material: %v", err)
	}
	if _, err := protector.Unprotect(
		context.Background(),
		tampered,
		aad,
	); err == nil {
		t.Fatal("tampered protected material was accepted")
	}
}

func TestProtectedMaterialAndAADAreOpaqueAndBounded(t *testing.T) {
	t.Parallel()

	if _, err := NewProtectedMaterial(nil); !errors.Is(err, ErrInvalidProtectedMaterial) {
		t.Fatalf("empty protected material: got %v", err)
	}
	if _, err := NewProtectedMaterial(
		bytes.Repeat([]byte{0x01}, ProtectedMaterialSizeMax+1),
	); !errors.Is(err, ErrInvalidProtectedMaterial) {
		t.Fatalf("oversized protected material: got %v", err)
	}
	if _, err := NewProtectionAAD(nil); !errors.Is(err, ErrInvalidProtectionAAD) {
		t.Fatalf("empty protection AAD: got %v", err)
	}
	if _, err := NewProtectionAAD(
		bytes.Repeat([]byte{0x01}, ProtectionAADSizeMax+1),
	); !errors.Is(err, ErrInvalidProtectionAAD) {
		t.Fatalf("oversized protection AAD: got %v", err)
	}
}

func TestIssueEnrollmentRejectsEmptyProtectedMaterial(t *testing.T) {
	t.Parallel()

	fixture := newServiceFixture(t)
	fixture.service.keyProtector = zeroResultKeyProtector{}
	tenantID, err := ParseTenantID("tenant-demo")
	if err != nil {
		t.Fatalf("parse tenant ID: %v", err)
	}
	if _, err := fixture.service.IssueEnrollment(
		context.Background(),
		tenantID,
	); !errors.Is(err, ErrInvalidProtectedMaterial) {
		t.Fatalf("empty protected material: got %v", err)
	}
	if fixture.repository.pendingCount() != 0 {
		t.Fatal("enrollment persisted after protector returned empty material")
	}
}

func TestIssueEnrollmentRejectsSignerKeyMismatchBeforePersistence(t *testing.T) {
	t.Parallel()

	fixture := newServiceFixture(t)
	otherSeed := sha256.Sum256([]byte("openpaycongo-other-identity"))
	fixture.service.identity = mismatchedIdentitySigner{
		publicKey:  fixture.identity.publicKey,
		signingKey: ed25519.NewKeyFromSeed(otherSeed[:]),
	}
	tenantID, err := ParseTenantID("tenant-demo")
	if err != nil {
		t.Fatalf("parse tenant ID: %v", err)
	}
	if _, err := fixture.service.IssueEnrollment(context.Background(), tenantID); !errors.Is(
		err,
		ErrIdentitySignerInconsistent,
	) {
		t.Fatalf("mismatched signer: got %v", err)
	}
	if fixture.repository.pendingCount() != 0 {
		t.Fatal("intent persisted with a signature from a different signing key")
	}
}

func TestIssueEnrollmentCreatesBoundedSignedOneTimeBootstrap(t *testing.T) {
	t.Parallel()

	fixture := newServiceFixture(t)
	tenantID, err := ParseTenantID("tenant-demo")
	if err != nil {
		t.Fatalf("parse tenant ID: %v", err)
	}
	qr, err := fixture.service.IssueEnrollment(
		context.Background(),
		tenantID,
	)
	if err != nil {
		t.Fatalf("issue enrollment: %v", err)
	}

	if qr.Version != ProtocolVersion {
		t.Fatalf("version: got %q", qr.Version)
	}
	if qr.ExpiresAt.Sub(fixture.clock.Now()) != 2*time.Minute {
		t.Fatalf("expiry: got %s", qr.ExpiresAt)
	}
	if !ed25519.Verify(
		fixture.identity.publicKey,
		qrSigningTranscript(qr),
		qr.Signature[:],
	) {
		t.Fatal("QR signature is invalid")
	}

	record, err := fixture.repository.pendingEnrollment(qr.IntentID)
	if err != nil {
		t.Fatalf("load pending enrollment: %v", err)
	}
	if record.ExpiresAt != qr.ExpiresAt {
		t.Fatalf("persisted expiry: got %s", record.ExpiresAt)
	}
	if record.ProtectedServerPrivateKey.IsZero() {
		t.Fatal("server private key was not protected")
	}
}

func TestRepositoryCreateIsInsertOnlyOnIntentCollision(t *testing.T) {
	t.Parallel()

	repository := newMemoryRepository()
	var intentID PairingIntentID
	intentID[0] = 0x42
	first := PendingEnrollment{ID: intentID, InvalidProofAttempts: 1}
	if err := repository.Create(context.Background(), first); err != nil {
		t.Fatalf("create first intent: %v", err)
	}
	second := PendingEnrollment{ID: intentID, InvalidProofAttempts: 2}
	if err := repository.Create(context.Background(), second); !errors.Is(err, ErrIntentCollision) {
		t.Fatalf("duplicate intent: got %v", err)
	}
	persisted, err := repository.pendingEnrollment(intentID)
	if err != nil {
		t.Fatalf("load first intent: %v", err)
	}
	if persisted.InvalidProofAttempts != first.InvalidProofAttempts {
		t.Fatalf("collision overwrote first intent: got attempt %d", persisted.InvalidProofAttempts)
	}
}

func TestVerifyPairingQRRejectsPublicKeyFingerprintMismatchBeforeTrustLookup(t *testing.T) {
	t.Parallel()

	fixture := newServiceFixture(t)
	tenantID, err := ParseTenantID("tenant-demo")
	if err != nil {
		t.Fatalf("parse tenant ID: %v", err)
	}
	qr, err := fixture.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("issue enrollment: %v", err)
	}
	trust := &countingTrustStore{fingerprint: qr.EnrollmentSigningFingerprint}
	if err := VerifyPairingQR(context.Background(), qr, fixture.clock.Now(), trust, LocalRecoveryAuthorization{}); err != nil {
		t.Fatalf("verify issued QR: %v", err)
	}
	if trust.lookups != 1 {
		t.Fatalf("trust lookups after valid QR: got %d", trust.lookups)
	}

	changed := qr
	changed.EnrollmentSigningPublicKey[0] ^= 0x01
	if err := VerifyPairingQR(
		context.Background(),
		changed,
		fixture.clock.Now(),
		trust,
		LocalRecoveryAuthorization{},
	); !errors.Is(err, ErrInvalidPairingQR) {
		t.Fatalf("mismatched public key/fingerprint: got %v", err)
	}
	if trust.lookups != 1 {
		t.Fatalf("mismatched QR reached trust lookup: got %d", trust.lookups)
	}
}

func TestFirstUseQRIsProvisionallyAcceptedWithoutPinButCannotActivateBeforeSAS(t *testing.T) {
	t.Parallel()

	fixture := newServiceFixture(t)
	fixture.service.trustMode = EnrollmentTrustFirstUseRequiresSAS
	tenantID, err := ParseTenantID("tenant-demo")
	if err != nil {
		t.Fatalf("parse tenant ID: %v", err)
	}
	qr, err := fixture.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("issue first-use QR: %v", err)
	}
	trust := &countingTrustStore{}
	if err := VerifyPairingQR(context.Background(), qr, fixture.clock.Now(), trust, LocalRecoveryAuthorization{}); !errors.Is(err, ErrUntrustedEnrollmentIdentity) {
		t.Fatalf("first use without local recovery authorization: %v", err)
	}
	recovery, err := NewLocalRecoveryAuthorization(true)
	if err != nil {
		t.Fatalf("authorize local recovery: %v", err)
	}
	if err := VerifyPairingQR(context.Background(), qr, fixture.clock.Now(), trust, recovery); err != nil {
		t.Fatalf("verify first-use QR: %v", err)
	}
	if trust.lookups != 2 {
		t.Fatalf("first-use QR did not inspect local pin state exactly once: %d lookups", trust.lookups)
	}
	trust.fingerprint = qr.EnrollmentSigningFingerprint
	if err := VerifyPairingQR(context.Background(), qr, fixture.clock.Now(), trust, recovery); !errors.Is(err, ErrUntrustedEnrollmentIdentity) {
		t.Fatalf("existing pin silently downgraded to first use: %v", err)
	}
	request, _ := buildCompletionRequest(t, qr)
	if _, err := fixture.service.CompleteEnrollment(context.Background(), request); err != nil {
		t.Fatalf("complete first-use pairing: %v", err)
	}
	if status := fixture.repository.onlyDevice(t).ActivationStatus; status != DevicePendingConfirmation {
		t.Fatalf("first-use pairing activated before SAS: got %q", status)
	}
}

func TestVerifyPairingQRUsesSharedCrossLanguageVector(t *testing.T) {
	t.Parallel()

	encoded, err := os.ReadFile(filepath.FromSlash("testdata/pairing-signed-qr.vector.json"))
	if err != nil {
		t.Fatalf("read shared signed QR vector: %v", err)
	}
	var vector struct {
		QR struct {
			Algorithms                   string `json:"algorithms"`
			Endpoint                     string `json:"endpoint"`
			EnrollmentSigningFingerprint string `json:"enrollment_signing_fingerprint"`
			EnrollmentSigningPublicKey   string `json:"enrollment_signing_public_key"`
			ExpiresAt                    string `json:"expires_at"`
			IntentID                     string `json:"intent_id"`
			IntentNonce                  string `json:"intent_nonce"`
			ServerPublic                 string `json:"server_key_agreement_public_key"`
			Signature                    string `json:"signature"`
			TrustMode                    string `json:"trust_mode"`
			Version                      string `json:"version"`
		} `json:"qr"`
	}
	if err := json.Unmarshal(encoded, &vector); err != nil {
		t.Fatalf("decode shared signed QR vector: %v", err)
	}
	qr := pairingQRFromVector(t, vector.QR)
	trust := &countingTrustStore{fingerprint: qr.EnrollmentSigningFingerprint}
	verificationTime := qr.ExpiresAt.Add(-time.Minute)
	if err := VerifyPairingQR(context.Background(), qr, verificationTime, trust, LocalRecoveryAuthorization{}); err != nil {
		t.Fatalf("verify shared signed QR vector: %v", err)
	}
}

func pairingQRFromVector(t *testing.T, wire struct {
	Algorithms                   string `json:"algorithms"`
	Endpoint                     string `json:"endpoint"`
	EnrollmentSigningFingerprint string `json:"enrollment_signing_fingerprint"`
	EnrollmentSigningPublicKey   string `json:"enrollment_signing_public_key"`
	ExpiresAt                    string `json:"expires_at"`
	IntentID                     string `json:"intent_id"`
	IntentNonce                  string `json:"intent_nonce"`
	ServerPublic                 string `json:"server_key_agreement_public_key"`
	Signature                    string `json:"signature"`
	TrustMode                    string `json:"trust_mode"`
	Version                      string `json:"version"`
}) PairingQR {
	t.Helper()
	decode := func(value string, size int) []byte {
		decoded, err := decodeBase64Fixed(value, size)
		if err != nil {
			t.Fatalf("decode shared signed QR vector: %v", err)
		}
		return decoded
	}
	expiresAt, err := time.Parse(timeFormat, wire.ExpiresAt)
	if err != nil {
		t.Fatalf("parse shared signed QR expiry: %v", err)
	}
	qr := PairingQR{
		Algorithms: wire.Algorithms,
		Endpoint:   wire.Endpoint,
		ExpiresAt:  expiresAt,
		Version:    wire.Version,
		TrustMode:  EnrollmentTrustMode(wire.TrustMode),
	}
	copy(qr.IntentID[:], decode(wire.IntentID, len(qr.IntentID)))
	copy(qr.IntentNonce[:], decode(wire.IntentNonce, len(qr.IntentNonce)))
	copy(qr.EnrollmentSigningFingerprint[:], decode(wire.EnrollmentSigningFingerprint, len(qr.EnrollmentSigningFingerprint)))
	copy(qr.EnrollmentSigningPublicKey[:], decode(wire.EnrollmentSigningPublicKey, len(qr.EnrollmentSigningPublicKey)))
	copy(qr.ServerKeyAgreementPublic[:], decode(wire.ServerPublic, len(qr.ServerKeyAgreementPublic)))
	copy(qr.Signature[:], decode(wire.Signature, len(qr.Signature)))
	return qr
}

func TestCompleteEnrollmentPersistsOnceAndSafelyReplaysExactRequest(t *testing.T) {
	t.Parallel()

	fixture := newServiceFixture(t)
	tenantID, err := ParseTenantID("tenant-demo")
	if err != nil {
		t.Fatalf("parse tenant ID: %v", err)
	}
	qr, err := fixture.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("issue enrollment: %v", err)
	}
	request, responseKey := buildCompletionRequest(t, qr)

	first, err := fixture.service.CompleteEnrollment(context.Background(), request)
	if err != nil {
		t.Fatalf("complete enrollment: %v", err)
	}
	if first.Status != CompletionPendingConfirmation {
		t.Fatalf("first status: got %q", first.Status)
	}
	assertCompletionResponseDecrypts(t, first, responseKey)

	replay, err := fixture.service.CompleteEnrollment(context.Background(), request)
	if err != nil {
		t.Fatalf("replay completion: %v", err)
	}
	if replay.Status != CompletionReplayed {
		t.Fatalf("replay status: got %q", replay.Status)
	}
	if replay.DeviceID != first.DeviceID {
		t.Fatal("replay returned a different device")
	}
	if string(replay.Ciphertext) != string(first.Ciphertext) {
		t.Fatal("replay returned a different encrypted response")
	}
	if fixture.repository.deviceCount() != 1 {
		t.Fatalf("created devices: got %d", fixture.repository.deviceCount())
	}
	persistedIntent, err := fixture.repository.pendingEnrollment(request.IntentID)
	if err != nil {
		t.Fatalf("load consumed intent: %v", err)
	}
	if !persistedIntent.ProtectedServerPrivateKey.IsZero() {
		t.Fatal("atomic completion retained the protected ephemeral private key")
	}
	if attempts := fixture.keyProtector.unprotectCount(); attempts > 3 {
		t.Fatalf("proof decryptions exceeded configured attempt bound: got %d", attempts)
	}
	device := fixture.repository.onlyDevice(t)
	if device.ActivationStatus != DevicePendingConfirmation {
		t.Fatalf("activation status: got %q", device.ActivationStatus)
	}
	if device.ProtectedInstallRoot.IsZero() {
		t.Fatal("protected install root was empty")
	}
	if len(device.ShortAuthenticationCode.String()) != 6 {
		t.Fatalf("short authentication code: got %q", device.ShortAuthenticationCode.String())
	}
	changed := request
	changed.Ciphertext = append([]byte(nil), request.Ciphertext...)
	changed.Ciphertext[0] ^= 0x01
	if _, err := fixture.service.CompleteEnrollment(context.Background(), changed); !errors.Is(
		err,
		ErrEnrollmentUnavailable,
	) {
		t.Fatalf("changed replay: got %v", err)
	}
}

func TestCompleteEnrollmentLocksAfterBoundedInvalidProofs(t *testing.T) {
	t.Parallel()

	fixture := newServiceFixture(t)
	tenantID, err := ParseTenantID("tenant-demo")
	if err != nil {
		t.Fatalf("parse tenant ID: %v", err)
	}
	qr, err := fixture.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("issue enrollment: %v", err)
	}
	valid, _ := buildCompletionRequest(t, qr)
	invalid := valid
	invalid.Ciphertext = append([]byte(nil), valid.Ciphertext...)
	invalid.Ciphertext[0] ^= 0x01

	for attempt := uint8(0); attempt < 3; attempt++ {
		if _, err := fixture.service.CompleteEnrollment(
			context.Background(),
			invalid,
		); !errors.Is(err, ErrEnrollmentUnavailable) {
			t.Fatalf("invalid attempt %d: got %v", attempt, err)
		}
	}
	exhausted, err := fixture.repository.pendingEnrollment(qr.IntentID)
	if err != nil {
		t.Fatalf("load exhausted intent: %v", err)
	}
	if !exhausted.ProtectedServerPrivateKey.IsZero() {
		t.Fatal("attempt exhaustion retained the protected ephemeral private key")
	}
	if exhausted.InvalidProofAttempts != 3 {
		t.Fatalf("completed invalid-proof attempts: got %d", exhausted.InvalidProofAttempts)
	}
	if _, err := fixture.service.CompleteEnrollment(
		context.Background(),
		valid,
	); !errors.Is(err, ErrEnrollmentUnavailable) {
		t.Fatalf("completion after attempt limit: got %v", err)
	}
	if fixture.repository.deviceCount() != 0 {
		t.Fatalf("created devices: got %d", fixture.repository.deviceCount())
	}
}

func TestCleanupExpiredEnrollmentsIsBoundedAndDestroysKeyMaterial(t *testing.T) {
	t.Parallel()

	fixture := newServiceFixture(t)
	if _, err := fixture.service.CleanupExpiredEnrollments(
		context.Background(),
		0,
	); !errors.Is(err, ErrInvalidCleanupLimit) {
		t.Fatalf("zero cleanup limit: got %v", err)
	}
	if _, err := fixture.service.CleanupExpiredEnrollments(
		context.Background(),
		CleanupPageSizeMax+1,
	); !errors.Is(err, ErrInvalidCleanupLimit) {
		t.Fatalf("oversized cleanup limit: got %v", err)
	}
	tenantID, err := ParseTenantID("tenant-demo")
	if err != nil {
		t.Fatalf("parse tenant ID: %v", err)
	}
	first, err := fixture.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("issue first enrollment: %v", err)
	}
	second, err := fixture.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("issue second enrollment: %v", err)
	}
	fixture.clock.now = first.ExpiresAt

	cleaned, err := fixture.service.CleanupExpiredEnrollments(context.Background(), 1)
	if err != nil {
		t.Fatalf("cleanup first page: %v", err)
	}
	if cleaned != 1 {
		t.Fatalf("first cleanup count: got %d", cleaned)
	}
	remainingProtected := 0
	for _, intentID := range []PairingIntentID{first.IntentID, second.IntentID} {
		record, loadErr := fixture.repository.pendingEnrollment(intentID)
		if loadErr != nil {
			t.Fatalf("load cleaned intent: %v", loadErr)
		}
		if !record.ProtectedServerPrivateKey.IsZero() {
			remainingProtected++
		}
	}
	if remainingProtected != 1 {
		t.Fatalf("protected intents after bounded page: got %d", remainingProtected)
	}
	cleaned, err = fixture.service.CleanupExpiredEnrollments(context.Background(), 1)
	if err != nil {
		t.Fatalf("cleanup second page: %v", err)
	}
	if cleaned != 1 {
		t.Fatalf("second cleanup count: got %d", cleaned)
	}
}

func TestCleanupExpiresPendingDeviceButPreservesExactReplayMetadata(t *testing.T) {
	t.Parallel()

	fixture := newServiceFixture(t)
	tenantID, err := ParseTenantID("tenant-demo")
	if err != nil {
		t.Fatalf("parse tenant ID: %v", err)
	}
	qr, err := fixture.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("issue enrollment: %v", err)
	}
	request, _ := buildCompletionRequest(t, qr)
	first, err := fixture.service.CompleteEnrollment(context.Background(), request)
	if err != nil {
		t.Fatalf("complete enrollment: %v", err)
	}
	fixture.clock.now = qr.ExpiresAt
	cleaned, err := fixture.service.CleanupExpiredEnrollments(context.Background(), 1)
	if err != nil || cleaned != 1 {
		t.Fatalf("cleanup pending device: count=%d error=%v", cleaned, err)
	}
	device := fixture.repository.onlyDevice(t)
	if device.ActivationStatus != DeviceExpired || !device.ProtectedInstallRoot.IsZero() {
		t.Fatalf("expired device retained authority or root: %#v", device)
	}
	replay, err := fixture.service.CompleteEnrollment(context.Background(), request)
	if err != nil {
		t.Fatalf("exact replay after cleanup: %v", err)
	}
	if replay.Status != CompletionReplayed || !bytes.Equal(replay.Ciphertext, first.Ciphertext) {
		t.Fatal("cleanup destroyed non-secret exact-replay metadata")
	}
}

func TestCompleteEnrollmentConcurrentRetryCreatesOneDevice(t *testing.T) {
	t.Parallel()

	fixture := newServiceFixture(t)
	tenantID, err := ParseTenantID("tenant-demo")
	if err != nil {
		t.Fatalf("parse tenant ID: %v", err)
	}
	qr, err := fixture.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("issue enrollment: %v", err)
	}
	request, _ := buildCompletionRequest(t, qr)

	const workers = 16
	results := make(chan CompletionResult, workers)
	errorsFound := make(chan error, workers)
	var waitGroup sync.WaitGroup
	for worker := 0; worker < workers; worker++ {
		waitGroup.Add(1)
		go func() {
			defer waitGroup.Done()
			result, err := fixture.service.CompleteEnrollment(context.Background(), request)
			if err != nil {
				errorsFound <- err
				return
			}
			results <- result
		}()
	}
	waitGroup.Wait()
	close(errorsFound)
	close(results)
	errorCount := 0
	for err := range errorsFound {
		if !errors.Is(err, ErrEnrollmentUnavailable) {
			t.Fatalf("concurrent completion: %v", err)
		}
		errorCount++
	}
	persistedCount := 0
	resultCount := 0
	for result := range results {
		resultCount++
		if result.Status == CompletionPendingConfirmation {
			persistedCount++
		}
	}
	if resultCount+errorCount != workers {
		t.Fatalf("terminal outcomes: got %d", resultCount+errorCount)
	}
	if persistedCount != 1 {
		t.Fatalf("persisted results: got %d", persistedCount)
	}
	if fixture.repository.deviceCount() != 1 {
		t.Fatalf("created devices: got %d", fixture.repository.deviceCount())
	}
	if attempts := fixture.keyProtector.unprotectCount(); attempts > int(CompletionReservationsMax) {
		t.Fatalf("proof decryptions exceeded in-flight reservation bound: got %d", attempts)
	}
	replay, err := fixture.service.CompleteEnrollment(context.Background(), request)
	if err != nil {
		t.Fatalf("retry after concurrent completion: %v", err)
	}
	if replay.Status != CompletionReplayed {
		t.Fatalf("retry status: got %q", replay.Status)
	}
}

func TestCommitFailureUsesNonCancelledBoundedCleanupAndClearsEphemeralKey(t *testing.T) {
	t.Parallel()

	fixture := newServiceFixture(t)
	tenantID, err := ParseTenantID("tenant-demo")
	if err != nil {
		t.Fatalf("parse tenant ID: %v", err)
	}
	qr, err := fixture.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("issue pairing intent: %v", err)
	}
	request, _ := buildCompletionRequest(t, qr)
	failing := &commitFailureRepository{Repository: fixture.repository}
	fixture.service.repository = failing
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := fixture.service.CompleteEnrollment(cancelled, request); !errors.Is(err, ErrEnrollmentUnavailable) {
		t.Fatalf("commit failure: got %v", err)
	}
	if !failing.abortContextWasLive {
		t.Fatal("commit cleanup inherited caller cancellation")
	}
	persisted, err := fixture.repository.pendingEnrollment(qr.IntentID)
	if err != nil {
		t.Fatalf("load failed intent: %v", err)
	}
	if !persisted.ProtectedServerPrivateKey.IsZero() {
		t.Fatal("commit failure retained protected ephemeral private key")
	}
}

func TestCommitThenErrorReconcilesExactCompletionWithoutBlindAbort(t *testing.T) {
	t.Parallel()
	fixture := newServiceFixture(t)
	tenantID, _ := ParseTenantID("tenant-demo")
	qr, err := fixture.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatal(err)
	}
	request, _ := buildCompletionRequest(t, qr)
	uncertain := &commitThenErrorRepository{Repository: fixture.repository}
	fixture.service.repository = uncertain
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	result, err := fixture.service.CompleteEnrollment(cancelled, request)
	if err != nil {
		t.Fatalf("reconcile commit-then-error: %v", err)
	}
	if result.Status != CompletionReplayed || fixture.repository.deviceCount() != 1 {
		t.Fatalf("reconciled result: %q devices=%d", result.Status, fixture.repository.deviceCount())
	}
	if uncertain.abortCalls != 0 {
		t.Fatal("unknown commit outcome was blindly aborted")
	}
	if !uncertain.reconcileContextWasLive {
		t.Fatal("unknown commit reconciliation inherited caller cancellation")
	}
}

func TestProtectorFailureTerminatesIntentAndClearsEphemeralKey(t *testing.T) {
	t.Parallel()
	fixture := newServiceFixture(t)
	tenantID, _ := ParseTenantID("tenant-demo")
	qr, err := fixture.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("issue pairing intent: %v", err)
	}
	fixture.repository.tamperProtectedIntent(t, qr.IntentID)
	request, _ := buildCompletionRequest(t, qr)
	if _, err := fixture.service.CompleteEnrollment(context.Background(), request); !errors.Is(err, ErrEnrollmentUnavailable) {
		t.Fatalf("protector failure: got %v", err)
	}
	persisted, err := fixture.repository.pendingEnrollment(qr.IntentID)
	if err != nil {
		t.Fatalf("load failed intent: %v", err)
	}
	if !persisted.ProtectedServerPrivateKey.IsZero() {
		t.Fatal("protector failure retained ephemeral key")
	}
}

func TestRepeatedRetryableUnprotectFailuresDoNotConsumeProofAttempts(t *testing.T) {
	t.Parallel()
	fixture := newServiceFixture(t)
	tenantID, _ := ParseTenantID("tenant-demo")
	qr, err := fixture.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatal(err)
	}
	request, _ := buildCompletionRequest(t, qr)
	const transientFailures = EnrollmentAttemptsMax + 2
	transient := &transientKeyProtector{
		delegate:          fixture.keyProtector,
		unprotectFailures: transientFailures,
	}
	fixture.service.keyProtector = transient
	for attempt := uint8(0); attempt < transientFailures; attempt++ {
		if _, err := fixture.service.CompleteEnrollment(context.Background(), request); !errors.Is(err, ErrEnrollmentUnavailable) {
			t.Fatalf("transient failure %d: %v", attempt+1, err)
		}
		persisted, err := fixture.repository.pendingEnrollment(qr.IntentID)
		if err != nil {
			t.Fatalf("load after transient failure %d: %v", attempt+1, err)
		}
		if persisted.InvalidProofAttempts != 0 {
			t.Fatalf("transient failure %d consumed proof attempt: got %d", attempt+1, persisted.InvalidProofAttempts)
		}
		if persisted.ProtectedServerPrivateKey.IsZero() {
			t.Fatalf("transient failure %d destroyed retry state", attempt+1)
		}
	}
	if _, err := fixture.service.CompleteEnrollment(context.Background(), request); err != nil {
		t.Fatalf("retry after dependency recovery: %v", err)
	}
}

func TestRepeatedRetryableProtectFailuresDoNotConsumeProofAttempts(t *testing.T) {
	t.Parallel()
	fixture := newServiceFixture(t)
	tenantID, _ := ParseTenantID("tenant-demo")
	qr, err := fixture.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatal(err)
	}
	request, _ := buildCompletionRequest(t, qr)
	const transientFailures = EnrollmentAttemptsMax + 2
	transient := &transientKeyProtector{
		delegate:        fixture.keyProtector,
		protectFailures: transientFailures,
	}
	fixture.service.keyProtector = transient
	for attempt := uint8(0); attempt < transientFailures; attempt++ {
		if _, err := fixture.service.CompleteEnrollment(context.Background(), request); !errors.Is(err, ErrEnrollmentUnavailable) {
			t.Fatalf("transient failure %d: %v", attempt+1, err)
		}
		persisted, err := fixture.repository.pendingEnrollment(qr.IntentID)
		if err != nil {
			t.Fatalf("load after transient failure %d: %v", attempt+1, err)
		}
		if persisted.InvalidProofAttempts != 0 {
			t.Fatalf("transient failure %d consumed proof attempt: got %d", attempt+1, persisted.InvalidProofAttempts)
		}
		if persisted.ProtectedServerPrivateKey.IsZero() {
			t.Fatalf("transient failure %d destroyed retry state", attempt+1)
		}
	}
	if _, err := fixture.service.CompleteEnrollment(context.Background(), request); err != nil {
		t.Fatalf("retry after dependency recovery: %v", err)
	}
}

func TestConcurrentRetryableUnprotectFailuresReleaseTheirOwnReservations(t *testing.T) {
	t.Parallel()
	assertConcurrentRetryableProtectorFailuresPreserveIntent(t, false)
}

func TestConcurrentRetryableProtectFailuresReleaseTheirOwnReservations(t *testing.T) {
	t.Parallel()
	assertConcurrentRetryableProtectorFailuresPreserveIntent(t, true)
}

func TestCompletionReservationsAreUniqueBoundedAndIdempotentlyReleasable(t *testing.T) {
	t.Parallel()
	fixture := newServiceFixture(t)
	tenantID, _ := ParseTenantID("tenant-demo")
	qr, err := fixture.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatal(err)
	}
	first, err := fixture.repository.BeginCompletionAttempt(
		context.Background(), qr.IntentID, fixture.clock.Now(), 3, 2,
	)
	if err != nil {
		t.Fatal(err)
	}
	second, err := fixture.repository.BeginCompletionAttempt(
		context.Background(), qr.IntentID, fixture.clock.Now(), 3, 2,
	)
	if err != nil {
		t.Fatal(err)
	}
	if first.ID == (CompletionReservationID{}) || second.ID == (CompletionReservationID{}) || first.ID == second.ID {
		t.Fatal("repository did not issue distinct non-zero reservation IDs")
	}
	if _, err := fixture.repository.BeginCompletionAttempt(
		context.Background(), qr.IntentID, fixture.clock.Now(), 3, 2,
	); !errors.Is(err, ErrEnrollmentUnavailable) {
		t.Fatalf("in-flight bound: %v", err)
	}
	if err := fixture.repository.ReleaseCompletionAttempt(context.Background(), qr.IntentID, first.ID); err != nil {
		t.Fatal(err)
	}
	if err := fixture.repository.ReleaseCompletionAttempt(context.Background(), qr.IntentID, first.ID); err != nil {
		t.Fatalf("idempotent release: %v", err)
	}
	if got := fixture.repository.inFlightReservationCount(qr.IntentID); got != 1 {
		t.Fatalf("in-flight reservations after exact replay: got %d", got)
	}
	persisted, err := fixture.repository.pendingEnrollment(qr.IntentID)
	if err != nil {
		t.Fatal(err)
	}
	if persisted.InvalidProofAttempts != 0 || persisted.ProtectedServerPrivateKey.IsZero() {
		t.Fatal("reservation pressure changed invalid-proof state or destroyed the intent key")
	}
	if err := fixture.repository.FinishFailedCompletion(
		context.Background(), qr.IntentID, second.ID, fixture.clock.Now(), 3,
	); err != nil {
		t.Fatal(err)
	}
	if err := fixture.repository.FinishFailedCompletion(
		context.Background(), qr.IntentID, second.ID, fixture.clock.Now(), 3,
	); err != nil {
		t.Fatalf("idempotent finish: %v", err)
	}
	persisted, _ = fixture.repository.pendingEnrollment(qr.IntentID)
	if persisted.InvalidProofAttempts != 1 {
		t.Fatalf("replayed finish double-counted invalid proof: got %d", persisted.InvalidProofAttempts)
	}
}

func assertConcurrentRetryableProtectorFailuresPreserveIntent(t *testing.T, failProtect bool) {
	t.Helper()
	fixture := newServiceFixture(t)
	tenantID, _ := ParseTenantID("tenant-demo")
	qr, err := fixture.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatal(err)
	}
	request, _ := buildCompletionRequest(t, qr)
	const concurrentCalls = uint8(4) // one more than this fixture's invalid-proof limit
	protector := &barrierRetryableKeyProtector{
		delegate:      fixture.keyProtector,
		entered:       make(chan struct{}, concurrentCalls),
		failProtect:   failProtect,
		failUnprotect: !failProtect,
		release:       make(chan struct{}),
	}
	fixture.service.keyProtector = protector

	errorsByCall := make(chan error, concurrentCalls)
	for call := uint8(0); call < concurrentCalls; call++ {
		go func() {
			_, completionErr := fixture.service.CompleteEnrollment(context.Background(), request)
			errorsByCall <- completionErr
		}()
	}
	for call := uint8(0); call < concurrentCalls; call++ {
		select {
		case <-protector.entered:
		case <-time.After(2 * time.Second):
			t.Fatalf("only %d of %d concurrent calls reached the protector", call, concurrentCalls)
		}
	}
	close(protector.release)
	for call := uint8(0); call < concurrentCalls; call++ {
		if completionErr := <-errorsByCall; !errors.Is(completionErr, ErrEnrollmentUnavailable) {
			t.Fatalf("concurrent transient failure %d: %v", call+1, completionErr)
		}
	}

	persisted, err := fixture.repository.pendingEnrollment(qr.IntentID)
	if err != nil {
		t.Fatal(err)
	}
	if persisted.InvalidProofAttempts != 0 {
		t.Fatalf("transient concurrency consumed invalid-proof attempts: got %d", persisted.InvalidProofAttempts)
	}
	if fixture.repository.inFlightReservationCount(qr.IntentID) != 0 {
		t.Fatal("transient concurrency leaked completion reservations")
	}
	if persisted.ProtectedServerPrivateKey.IsZero() {
		t.Fatal("transient concurrency destroyed the protected ephemeral key")
	}
	fixture.service.keyProtector = fixture.keyProtector
	if _, err := fixture.service.CompleteEnrollment(context.Background(), request); err != nil {
		t.Fatalf("completion after dependency recovery: %v", err)
	}
}

func TestCompletionCommitBoundaryIsStrictlyBeforeExpiry(t *testing.T) {
	t.Parallel()
	tenantID, _ := ParseTenantID("tenant-demo")
	before := newServiceFixture(t)
	beforeQR, err := before.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatal(err)
	}
	beforeRequest, _ := buildCompletionRequest(t, beforeQR)
	before.clock.now = beforeQR.ExpiresAt.Add(-time.Nanosecond)
	if _, err := before.service.CompleteEnrollment(context.Background(), beforeRequest); err != nil {
		t.Fatalf("commit before expiry: %v", err)
	}
	after := newServiceFixture(t)
	afterQR, err := after.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatal(err)
	}
	afterRequest, _ := buildCompletionRequest(t, afterQR)
	after.clock.now = afterQR.ExpiresAt
	if _, err := after.service.CompleteEnrollment(context.Background(), afterRequest); !errors.Is(err, ErrEnrollmentUnavailable) {
		t.Fatalf("commit at expiry: %v", err)
	}
	persisted, _ := after.repository.pendingEnrollment(afterQR.IntentID)
	if !persisted.ProtectedServerPrivateKey.IsZero() {
		t.Fatal("expired completion retained ephemeral key")
	}
}

func TestCleanupFailureIsObservableWithoutChangingPublicUnavailableClass(t *testing.T) {
	t.Parallel()

	fixture := newServiceFixture(t)
	tenantID, err := ParseTenantID("tenant-demo")
	if err != nil {
		t.Fatalf("parse tenant ID: %v", err)
	}
	qr, err := fixture.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("issue pairing intent: %v", err)
	}
	request, _ := buildCompletionRequest(t, qr)
	fixture.service.repository = &commitFailureRepository{
		Repository: fixture.repository,
		abortErr:   errors.New("cleanup store unavailable"),
	}
	_, err = fixture.service.CompleteEnrollment(context.Background(), request)
	if !errors.Is(err, ErrEnrollmentUnavailable) || !errors.Is(err, ErrCompletionCleanupFailed) {
		t.Fatalf("cleanup failure classes: got %v", err)
	}
}

func TestConfirmPairingRequiresAuthenticatedTenantMatchBeforeActivation(t *testing.T) {
	t.Parallel()

	fixture := newServiceFixture(t)
	tenantID, err := ParseTenantID("tenant-demo")
	if err != nil {
		t.Fatalf("parse tenant ID: %v", err)
	}
	qr, err := fixture.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("issue pairing intent: %v", err)
	}
	request, _ := buildCompletionRequest(t, qr)
	if _, err := fixture.service.CompleteEnrollment(context.Background(), request); err != nil {
		t.Fatalf("complete pairing: %v", err)
	}
	principal := verifiedAdmin(t, tenantID)

	status, err := fixture.service.ConfirmPairing(
		context.Background(),
		principal,
		qr.IntentID,
		confirmationRequestID(1),
		ConfirmationCodesMatch,
		ConfirmationReasonCodesComparedMatch,
	)
	if err != nil {
		t.Fatalf("confirm pairing: %v", err)
	}
	if status != DeviceActive {
		t.Fatalf("activation status: got %q", status)
	}
}

func TestConfirmPairingRequiresVerifiedAdminAndExactRequestReplay(t *testing.T) {
	t.Parallel()

	fixture := newServiceFixture(t)
	tenantID, err := ParseTenantID("tenant-demo")
	if err != nil {
		t.Fatalf("parse tenant ID: %v", err)
	}
	principal, err := NewVerifiedAdminPrincipal("admin-001", tenantID)
	if err != nil {
		t.Fatalf("verified admin principal: %v", err)
	}
	qr, err := fixture.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("issue pairing intent: %v", err)
	}
	request, _ := buildCompletionRequest(t, qr)
	if _, err := fixture.service.CompleteEnrollment(context.Background(), request); err != nil {
		t.Fatalf("complete pairing: %v", err)
	}
	var requestID ConfirmationRequestID
	requestID[0] = 1
	status, err := fixture.service.ConfirmPairing(
		context.Background(),
		principal,
		qr.IntentID,
		requestID,
		ConfirmationCodesMatch,
		ConfirmationReasonCodesComparedMatch,
	)
	if err != nil {
		t.Fatalf("confirm pairing: %v", err)
	}
	if status != DeviceActive {
		t.Fatalf("activation status: got %q", status)
	}
	fixture.clock.now = fixture.clock.now.Add(time.Second)
	replay, err := fixture.service.ConfirmPairing(
		context.Background(),
		principal,
		qr.IntentID,
		requestID,
		ConfirmationCodesMatch,
		ConfirmationReasonCodesComparedMatch,
	)
	if err != nil || replay != DeviceActive {
		t.Fatalf("exact confirmation replay: status=%q error=%v", replay, err)
	}
	if _, err := fixture.service.ConfirmPairing(
		context.Background(),
		principal,
		qr.IntentID,
		requestID,
		ConfirmationCodesMismatch,
		ConfirmationReasonCodesComparedMismatch,
	); !errors.Is(err, ErrConfirmationConflict) {
		t.Fatalf("changed payload for confirmation request ID: got %v", err)
	}
	audit, err := fixture.repository.confirmationAudit(qr.IntentID)
	if err != nil {
		t.Fatalf("confirmation audit: %v", err)
	}
	if audit.Actor.Subject() != "admin-001" || audit.RequestID != requestID {
		t.Fatal("confirmation audit lost actor or request identity")
	}
	if audit.ConfirmedAt != qr.ExpiresAt.Add(-2*time.Minute) {
		t.Fatalf("confirmation replay overwrote audit time: got %s", audit.ConfirmedAt)
	}
}

func TestGetPairingConfirmationExposesSASOnlyWhilePending(t *testing.T) {
	t.Parallel()

	fixture := newServiceFixture(t)
	tenantID, err := ParseTenantID("tenant-demo")
	if err != nil {
		t.Fatalf("parse tenant ID: %v", err)
	}
	principal := verifiedAdmin(t, tenantID)
	qr, err := fixture.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("issue pairing intent: %v", err)
	}
	request, _ := buildCompletionRequest(t, qr)
	if _, err := fixture.service.CompleteEnrollment(context.Background(), request); err != nil {
		t.Fatalf("complete pairing: %v", err)
	}
	pending, err := fixture.service.GetPairingConfirmation(
		context.Background(),
		principal,
		qr.IntentID,
	)
	if err != nil {
		t.Fatalf("get pending confirmation: %v", err)
	}
	if pending.Status != DevicePendingConfirmation || !pending.IncludesShortAuthenticationCode || len(pending.ShortAuthenticationCode.String()) != 6 {
		t.Fatalf("pending confirmation view: %#v", pending)
	}
	if _, err := fixture.service.ConfirmPairing(
		context.Background(),
		principal,
		qr.IntentID,
		confirmationRequestID(1),
		ConfirmationCodesMatch,
		ConfirmationReasonCodesComparedMatch,
	); err != nil {
		t.Fatalf("confirm pairing: %v", err)
	}
	active, err := fixture.service.GetPairingConfirmation(
		context.Background(),
		principal,
		qr.IntentID,
	)
	if err != nil {
		t.Fatalf("get active confirmation: %v", err)
	}
	if active.Status != DeviceActive || active.IncludesShortAuthenticationCode || active.ShortAuthenticationCode != (ShortAuthenticationCode{}) {
		t.Fatalf("active confirmation exposed SAS: %#v", active)
	}
}

func TestPhoneBearerLearnsAndAcknowledgesTerminalPairingStatusWithoutAdminOAuth(t *testing.T) {
	t.Parallel()

	fixture := newServiceFixture(t)
	tenantID, err := ParseTenantID("tenant-demo")
	if err != nil {
		t.Fatalf("parse tenant ID: %v", err)
	}
	qr, err := fixture.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("issue pairing intent: %v", err)
	}
	request, responseKeys := buildCompletionRequest(t, qr)
	result, err := fixture.service.CompleteEnrollment(context.Background(), request)
	if err != nil {
		t.Fatalf("complete pairing: %v", err)
	}
	response := assertCompletionResponseDecrypts(t, result, responseKeys)
	tokenBytes, err := base64.RawURLEncoding.DecodeString(response.PairingStatusToken)
	if err != nil {
		t.Fatalf("decode pairing status bearer: %v", err)
	}
	var token PairingStatusToken
	copy(token[:], tokenBytes)
	pending, err := fixture.service.GetPhonePairingStatus(context.Background(), token)
	if err != nil || pending.Status != DevicePendingConfirmation {
		t.Fatalf("phone pending status: got %q, %v", pending.Status, err)
	}
	if err := fixture.service.AcknowledgePhonePairingStatus(
		context.Background(), token, DevicePendingConfirmation,
	); !errors.Is(err, ErrEnrollmentUnavailable) {
		t.Fatalf("pending acknowledgement: got %v", err)
	}
	if _, err := fixture.service.ConfirmPairing(
		context.Background(), verifiedAdmin(t, tenantID), qr.IntentID,
		confirmationRequestID(0x44), ConfirmationCodesMatch, ConfirmationReasonCodesComparedMatch,
	); err != nil {
		t.Fatalf("confirm pairing: %v", err)
	}
	active, err := fixture.service.GetPhonePairingStatus(context.Background(), token)
	if err != nil || active.Status != DeviceActive {
		t.Fatalf("phone terminal status: got %q, %v", active.Status, err)
	}
	if err := fixture.service.AcknowledgePhonePairingStatus(
		context.Background(), token, DeviceActive,
	); err != nil {
		t.Fatalf("acknowledge terminal status: %v", err)
	}
	if err := fixture.service.AcknowledgePhonePairingStatus(
		context.Background(), token, DeviceActive,
	); err != nil {
		t.Fatalf("replay terminal acknowledgement: %v", err)
	}
	var wrongToken PairingStatusToken
	wrongToken[0] = 1
	if _, err := fixture.service.GetPhonePairingStatus(
		context.Background(), wrongToken,
	); !errors.Is(err, ErrEnrollmentUnavailable) {
		t.Fatalf("wrong bearer status: got %v", err)
	}
}

func TestConfirmPairingRejectsWrongTenantWithoutChangingPendingDevice(t *testing.T) {
	t.Parallel()

	fixture := newServiceFixture(t)
	tenantID, err := ParseTenantID("tenant-demo")
	if err != nil {
		t.Fatalf("parse tenant ID: %v", err)
	}
	otherTenantID, err := ParseTenantID("tenant-other")
	if err != nil {
		t.Fatalf("parse other tenant ID: %v", err)
	}
	qr, err := fixture.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("issue pairing intent: %v", err)
	}
	request, _ := buildCompletionRequest(t, qr)
	if _, err := fixture.service.CompleteEnrollment(context.Background(), request); err != nil {
		t.Fatalf("complete pairing: %v", err)
	}
	_, err = fixture.service.ConfirmPairing(
		context.Background(),
		verifiedAdmin(t, otherTenantID),
		qr.IntentID,
		confirmationRequestID(1),
		ConfirmationCodesMatch,
		ConfirmationReasonCodesComparedMatch,
	)
	if !errors.Is(err, ErrEnrollmentUnavailable) {
		t.Fatalf("wrong-tenant confirmation: got %v", err)
	}
	if status := fixture.repository.onlyDevice(t).ActivationStatus; status != DevicePendingConfirmation {
		t.Fatalf("wrong-tenant confirmation changed status: got %q", status)
	}
}

func TestConfirmPairingConcurrentContradictoryDecisionsHaveOneWinner(t *testing.T) {
	t.Parallel()

	fixture := newServiceFixture(t)
	tenantID, err := ParseTenantID("tenant-demo")
	if err != nil {
		t.Fatalf("parse tenant ID: %v", err)
	}
	qr, err := fixture.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("issue pairing intent: %v", err)
	}
	request, _ := buildCompletionRequest(t, qr)
	if _, err := fixture.service.CompleteEnrollment(context.Background(), request); err != nil {
		t.Fatalf("complete pairing: %v", err)
	}
	principal := verifiedAdmin(t, tenantID)
	type outcome struct {
		err    error
		status DeviceActivationStatus
	}
	outcomes := make(chan outcome, 2)
	var waitGroup sync.WaitGroup
	commands := []struct {
		decision  ConfirmationDecision
		reason    ConfirmationReason
		requestID ConfirmationRequestID
	}{
		{ConfirmationCodesMatch, ConfirmationReasonCodesComparedMatch, confirmationRequestID(1)},
		{ConfirmationCodesMismatch, ConfirmationReasonCodesComparedMismatch, confirmationRequestID(2)},
	}
	for _, command := range commands {
		command := command
		waitGroup.Add(1)
		go func() {
			defer waitGroup.Done()
			status, confirmErr := fixture.service.ConfirmPairing(
				context.Background(),
				principal,
				qr.IntentID,
				command.requestID,
				command.decision,
				command.reason,
			)
			outcomes <- outcome{err: confirmErr, status: status}
		}()
	}
	waitGroup.Wait()
	close(outcomes)
	winners := 0
	conflicts := 0
	for result := range outcomes {
		if result.err == nil {
			winners++
			continue
		}
		if errors.Is(result.err, ErrConfirmationConflict) {
			conflicts++
			continue
		}
		t.Fatalf("unexpected confirmation race error: %v", result.err)
	}
	if winners != 1 || conflicts != 1 {
		t.Fatalf("race outcomes: winners=%d conflicts=%d", winners, conflicts)
	}
}

func TestConfirmPairingMismatchRevokesPendingDevice(t *testing.T) {
	t.Parallel()

	fixture := newServiceFixture(t)
	tenantID, err := ParseTenantID("tenant-demo")
	if err != nil {
		t.Fatalf("parse tenant ID: %v", err)
	}
	qr, err := fixture.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("issue pairing intent: %v", err)
	}
	request, _ := buildCompletionRequest(t, qr)
	if _, err := fixture.service.CompleteEnrollment(context.Background(), request); err != nil {
		t.Fatalf("complete pairing: %v", err)
	}
	principal := verifiedAdmin(t, tenantID)

	status, err := fixture.service.ConfirmPairing(
		context.Background(),
		principal,
		qr.IntentID,
		confirmationRequestID(1),
		ConfirmationCodesMismatch,
		ConfirmationReasonCodesComparedMismatch,
	)
	if err != nil {
		t.Fatalf("reject pairing: %v", err)
	}
	if status != DeviceRevoked {
		t.Fatalf("activation status: got %q", status)
	}
}

func TestConfirmPairingAfterIntentExpiryRevokesPendingDevice(t *testing.T) {
	t.Parallel()

	fixture := newServiceFixture(t)
	tenantID, err := ParseTenantID("tenant-demo")
	if err != nil {
		t.Fatalf("parse tenant ID: %v", err)
	}
	qr, err := fixture.service.IssueEnrollment(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("issue pairing intent: %v", err)
	}
	request, _ := buildCompletionRequest(t, qr)
	if _, err := fixture.service.CompleteEnrollment(context.Background(), request); err != nil {
		t.Fatalf("complete pairing: %v", err)
	}
	fixture.clock.now = qr.ExpiresAt
	principal := verifiedAdmin(t, tenantID)

	status, err := fixture.service.ConfirmPairing(
		context.Background(),
		principal,
		qr.IntentID,
		confirmationRequestID(1),
		ConfirmationCodesMatch,
		ConfirmationReasonCodesComparedMatch,
	)
	if err != nil {
		t.Fatalf("expire pairing: %v", err)
	}
	if status != DeviceExpired {
		t.Fatalf("activation status: got %q", status)
	}
	device := fixture.repository.onlyDevice(t)
	if !device.ProtectedInstallRoot.IsZero() {
		t.Fatal("expired pairing retained protected install root")
	}
}

func TestPairingKeyScheduleVector(t *testing.T) {
	t.Parallel()

	encoded, err := os.ReadFile(filepath.FromSlash("testdata/pairing-key-schedule.vector.json"))
	if err != nil {
		t.Fatalf("read shared pairing vector: %v", err)
	}
	var vector struct {
		Algorithms                      string `json:"algorithms"`
		ClientPublicHex                 string `json:"client_key_agreement_public_key_hex"`
		EnrollmentSigningFingerprintHex string `json:"enrollment_signing_fingerprint_hex"`
		IntentIDHex                     string `json:"intent_id_hex"`
		IntentNonceHex                  string `json:"intent_nonce_hex"`
		ServerPublicHex                 string `json:"server_key_agreement_public_key_hex"`
		SharedSecretHex                 string `json:"shared_secret_hex"`
		Version                         string `json:"version"`
		Expected                        struct {
			ClientToServerHex             string `json:"c2s_hex"`
			InstallRootHex                string `json:"install_root_hex"`
			ServerToClientAEADHex         string `json:"s2c_aead_hex"`
			ServerToClientConfirmationHex string `json:"s2c_confirm_hex"`
			ShortAuthenticationCode       string `json:"short_authentication_code"`
		} `json:"expected"`
	}
	if err := json.Unmarshal(encoded, &vector); err != nil {
		t.Fatalf("decode shared pairing vector: %v", err)
	}
	if vector.Version != ProtocolVersion || vector.Algorithms != AlgorithmSuite {
		t.Fatal("shared pairing vector version or algorithm drifted")
	}
	sharedSecret := decodeVectorHex(t, vector.SharedSecretHex, SecretSize)
	var intentID PairingIntentID
	var intentNonce IntentNonce
	var signingFingerprint EnrollmentSigningFingerprint
	var serverPublic ServerKeyAgreementPublic
	var clientPublic ClientKeyAgreementPublic
	copy(intentID[:], decodeVectorHex(t, vector.IntentIDHex, len(intentID)))
	copy(intentNonce[:], decodeVectorHex(t, vector.IntentNonceHex, len(intentNonce)))
	copy(signingFingerprint[:], decodeVectorHex(t, vector.EnrollmentSigningFingerprintHex, len(signingFingerprint)))
	copy(serverPublic[:], decodeVectorHex(t, vector.ServerPublicHex, len(serverPublic)))
	copy(clientPublic[:], decodeVectorHex(t, vector.ClientPublicHex, len(clientPublic)))
	record := PendingEnrollment{
		EnrollmentSigningFingerprint: signingFingerprint,
		ID:                           intentID,
		IntentNonce:                  intentNonce,
		ServerKeyAgreementPublic:     serverPublic,
	}
	keys, err := deriveSessionKeys(sharedSecret, record, clientPublic)
	if err != nil {
		t.Fatalf("derive vector: %v", err)
	}
	defer keys.wipe()
	if bytes.Equal(keys.serverToClientAEAD[:], keys.serverToClientConfirmation[:]) {
		t.Fatal("response AEAD and key-confirmation keys were not separated")
	}
	derivedValues := []struct {
		name     string
		actual   []byte
		expected string
	}{
		{"c2s", keys.clientToServer[:], vector.Expected.ClientToServerHex},
		{"s2c AEAD", keys.serverToClientAEAD[:], vector.Expected.ServerToClientAEADHex},
		{"s2c confirmation", keys.serverToClientConfirmation[:], vector.Expected.ServerToClientConfirmationHex},
		{"install root", keys.installRoot[:], vector.Expected.InstallRootHex},
	}
	for _, derived := range derivedValues {
		if actual := hex.EncodeToString(derived.actual); actual != derived.expected {
			t.Fatalf("%s: got %s", derived.name, actual)
		}
	}
	if keys.shortCode.String() != vector.Expected.ShortAuthenticationCode {
		t.Fatalf("short authentication code: got %s", keys.shortCode.String())
	}
}

func TestFullPairingProtocolVectorMatchesGoCrypto(t *testing.T) {
	t.Parallel()
	encoded, err := os.ReadFile(filepath.FromSlash("testdata/pairing-protocol.vector.json"))
	if err != nil {
		t.Fatalf("read protocol vector: %v", err)
	}
	var vector struct {
		Version string `json:"version"`
		Inputs  struct {
			ServerPrivateHex     string `json:"server_private_hex"`
			ServerPublic         string `json:"server_public"`
			ClientPrivateHex     string `json:"client_private_hex"`
			ClientPublic         string `json:"client_public"`
			IntentID             string `json:"intent_id"`
			IntentNonce          string `json:"intent_nonce"`
			Fingerprint          string `json:"enrollment_signing_fingerprint"`
			C2SNonce             string `json:"c2s_nonce"`
			DeviceID             string `json:"device_id"`
			S2CNonce             string `json:"s2c_nonce"`
			DeviceSigningSeedHex string `json:"device_signing_seed_hex"`
			DeviceSigningPublic  string `json:"device_signing_public"`
		} `json:"inputs"`
		Expected struct {
			Shared               string          `json:"shared_secret_hex"`
			C2S                  string          `json:"c2s_hex"`
			S2CAead              string          `json:"s2c_aead_hex"`
			S2CConfirm           string          `json:"s2c_confirm_hex"`
			InstallRoot          string          `json:"install_root_hex"`
			C2SCiphertext        string          `json:"c2s_ciphertext"`
			S2CCiphertext        string          `json:"s2c_ciphertext"`
			KeyConfirmation      string          `json:"key_confirmation"`
			DeviceProofSignature string          `json:"device_proof_signature"`
			ProofPlaintext       json.RawMessage `json:"proof_plaintext"`
			ResponsePlaintext    json.RawMessage `json:"response_plaintext"`
		} `json:"expected"`
	}
	if err := json.Unmarshal(encoded, &vector); err != nil {
		t.Fatalf("decode protocol vector: %v", err)
	}
	decodeB64 := func(value string) []byte {
		decoded, decodeErr := base64.RawURLEncoding.DecodeString(value)
		if decodeErr != nil {
			t.Fatalf("decode vector base64: %v", decodeErr)
		}
		return decoded
	}
	serverPrivate, err := ecdh.X25519().NewPrivateKey(decodeVectorHex(t, vector.Inputs.ServerPrivateHex, SecretSize))
	if err != nil {
		t.Fatalf("server private: %v", err)
	}
	clientPrivate, err := ecdh.X25519().NewPrivateKey(decodeVectorHex(t, vector.Inputs.ClientPrivateHex, SecretSize))
	if err != nil {
		t.Fatalf("client private: %v", err)
	}
	if base64.RawURLEncoding.EncodeToString(serverPrivate.PublicKey().Bytes()) != vector.Inputs.ServerPublic || base64.RawURLEncoding.EncodeToString(clientPrivate.PublicKey().Bytes()) != vector.Inputs.ClientPublic {
		t.Fatal("derived X25519 public key drifted")
	}
	shared, err := clientPrivate.ECDH(serverPrivate.PublicKey())
	if err != nil {
		t.Fatalf("X25519: %v", err)
	}
	if hex.EncodeToString(shared) != vector.Expected.Shared {
		t.Fatal("shared secret drifted")
	}
	var record PendingEnrollment
	copy(record.ID[:], decodeB64(vector.Inputs.IntentID))
	copy(record.IntentNonce[:], decodeB64(vector.Inputs.IntentNonce))
	copy(record.EnrollmentSigningFingerprint[:], decodeB64(vector.Inputs.Fingerprint))
	copy(record.ServerKeyAgreementPublic[:], decodeB64(vector.Inputs.ServerPublic))
	var clientPublic ClientKeyAgreementPublic
	copy(clientPublic[:], decodeB64(vector.Inputs.ClientPublic))
	keys, err := deriveSessionKeys(shared, record, clientPublic)
	if err != nil {
		t.Fatalf("derive keys: %v", err)
	}
	defer keys.wipe()
	for name, values := range map[string][2]string{"c2s": {hex.EncodeToString(keys.clientToServer[:]), vector.Expected.C2S}, "s2c-aead": {hex.EncodeToString(keys.serverToClientAEAD[:]), vector.Expected.S2CAead}, "s2c-confirm": {hex.EncodeToString(keys.serverToClientConfirmation[:]), vector.Expected.S2CConfirm}, "install-root": {hex.EncodeToString(keys.installRoot[:]), vector.Expected.InstallRoot}} {
		if values[0] != values[1] {
			t.Fatalf("%s drifted", name)
		}
	}
	var request CompletionRequest
	request.Version = vector.Version
	request.IntentID = record.ID
	request.ClientKeyAgreementPublic = clientPublic
	copy(request.Nonce[:], decodeB64(vector.Inputs.C2SNonce))
	request.Ciphertext = decodeB64(vector.Expected.C2SCiphertext)
	plaintext, err := openProofCiphertext(record, request, keys.clientToServer[:])
	if err != nil {
		t.Fatalf("open c2s proof: %v", err)
	}
	opened, err := decodeAndVerifyProof(record, request, plaintext)
	if err != nil {
		t.Fatalf("verify Ed25519 proof: %v", err)
	}
	deviceSeed := decodeVectorHex(t, vector.Inputs.DeviceSigningSeedHex, ed25519.SeedSize)
	devicePrivate := ed25519.NewKeyFromSeed(deviceSeed)
	devicePublic := devicePrivate.Public().(ed25519.PublicKey)
	if base64.RawURLEncoding.EncodeToString(devicePublic) != vector.Inputs.DeviceSigningPublic || opened.deviceSigningPublicKey != DeviceSigningPublicKey(devicePublic) {
		t.Fatal("derived Ed25519 public key drifted")
	}
	proofTranscript := deviceProofTranscriptFields(record.ID, record.IntentNonce, record.EnrollmentSigningFingerprint, opened.installID, clientPublic[:], devicePublic)
	if base64.RawURLEncoding.EncodeToString(ed25519.Sign(devicePrivate, proofTranscript.Bytes())) != vector.Expected.DeviceProofSignature {
		t.Fatal("derived Ed25519 signature drifted")
	}
	var actualProof, expectedProof any
	if json.Unmarshal(plaintext, &actualProof) != nil || json.Unmarshal(vector.Expected.ProofPlaintext, &expectedProof) != nil || !reflect.DeepEqual(actualProof, expectedProof) {
		t.Fatal("proof plaintext fields drifted")
	}
	var deviceID DeviceID
	copy(deviceID[:], decodeB64(vector.Inputs.DeviceID))
	responseAAD := completionResponseAAD(deviceID)
	block, _ := aes.NewCipher(keys.serverToClientAEAD[:])
	aead, _ := cipher.NewGCM(block)
	sealed := decodeB64(vector.Expected.S2CCiphertext)
	var responseNonce Nonce
	copy(responseNonce[:], decodeB64(vector.Inputs.S2CNonce))
	responsePlaintext, err := aead.Open(nil, responseNonce[:], sealed, responseAAD)
	if err != nil {
		t.Fatalf("open s2c response: %v", err)
	}
	var response completionResponseWire
	if err := json.Unmarshal(responsePlaintext, &response); err != nil {
		t.Fatalf("decode s2c response: %v", err)
	}
	var actualResponse, expectedResponse any
	if json.Unmarshal(responsePlaintext, &actualResponse) != nil || json.Unmarshal(vector.Expected.ResponsePlaintext, &expectedResponse) != nil || !reflect.DeepEqual(actualResponse, expectedResponse) {
		t.Fatal("response plaintext fields drifted")
	}
	confirmation := hmac.New(sha256.New, keys.serverToClientConfirmation[:])
	_, _ = confirmation.Write(responseAAD)
	if base64.RawURLEncoding.EncodeToString(confirmation.Sum(nil)) != vector.Expected.KeyConfirmation || response.KeyConfirmation != vector.Expected.KeyConfirmation {
		t.Fatal("key confirmation drifted")
	}
}

func decodeVectorHex(t *testing.T, value string, expectedLength int) []byte {
	t.Helper()
	decoded, err := hex.DecodeString(value)
	if err != nil {
		t.Fatalf("decode shared pairing vector: %v", err)
	}
	if len(decoded) != expectedLength {
		t.Fatalf("shared pairing vector length: got %d, want %d", len(decoded), expectedLength)
	}
	return decoded
}

type responseTestKeys struct {
	aead         []byte
	confirmation []byte
}

func buildCompletionRequest(t *testing.T, qr PairingQR) (CompletionRequest, responseTestKeys) {
	t.Helper()

	clientSeed := sha256.Sum256([]byte("openpaycongo-client-x25519"))
	clientPrivateKey, err := ecdh.X25519().NewPrivateKey(clientSeed[:])
	if err != nil {
		t.Fatalf("client private key: %v", err)
	}
	serverPublicKey, err := ecdh.X25519().NewPublicKey(qr.ServerKeyAgreementPublic[:])
	if err != nil {
		t.Fatalf("server public key: %v", err)
	}
	sharedSecret, err := clientPrivateKey.ECDH(serverPublicKey)
	if err != nil {
		t.Fatalf("derive shared secret: %v", err)
	}
	clientPublicKey := clientPrivateKey.PublicKey().Bytes()
	proofKey, responseKey := deriveTestSessionKeys(t, sharedSecret, qr, clientPublicKey)

	deviceSeed := sha256.Sum256([]byte("openpaycongo-device-ed25519"))
	devicePrivateKey := ed25519.NewKeyFromSeed(deviceSeed[:])
	devicePublicKey := devicePrivateKey.Public().(ed25519.PublicKey)
	installID := "install-018f4b7a4f897a6b"
	proofSignature := ed25519.Sign(
		devicePrivateKey,
		deviceProofTranscript(qr, installID, clientPublicKey, devicePublicKey).Bytes(),
	)
	proof := encryptedProofWire{
		DeviceSigningPublicKey: base64.RawURLEncoding.EncodeToString(devicePublicKey),
		InstallID:              installID,
		Signature:              base64.RawURLEncoding.EncodeToString(proofSignature),
		Version:                ProtocolVersion,
	}
	plaintext, err := json.Marshal(proof)
	if err != nil {
		t.Fatalf("marshal proof: %v", err)
	}

	block, err := aes.NewCipher(proofKey)
	if err != nil {
		t.Fatalf("proof cipher: %v", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatalf("proof AEAD: %v", err)
	}
	nonceBytes := sha256.Sum256([]byte("openpaycongo-proof-nonce"))
	var nonce Nonce
	copy(nonce[:], nonceBytes[:len(nonce)])
	var clientPublic ClientKeyAgreementPublic
	copy(clientPublic[:], clientPublicKey)
	request := CompletionRequest{
		Ciphertext:               aead.Seal(nil, nonce[:], plaintext, completionAAD(qr, clientPublic)),
		ClientKeyAgreementPublic: clientPublic,
		IntentID:                 qr.IntentID,
		Nonce:                    nonce,
		Version:                  ProtocolVersion,
	}
	return request, responseKey
}

func deriveTestSessionKeys(
	t *testing.T,
	sharedSecret []byte,
	qr PairingQR,
	clientPublicKey []byte,
) ([]byte, responseTestKeys) {
	t.Helper()
	var clientPublic ClientKeyAgreementPublic
	copy(clientPublic[:], clientPublicKey)
	record := PendingEnrollment{
		EnrollmentSigningFingerprint: qr.EnrollmentSigningFingerprint,
		ID:                           qr.IntentID,
		IntentNonce:                  qr.IntentNonce,
		ServerKeyAgreementPublic:     qr.ServerKeyAgreementPublic,
	}
	keys, err := deriveSessionKeys(sharedSecret, record, clientPublic)
	if err != nil {
		t.Fatalf("derive session keys: %v", err)
	}
	defer keys.wipe()
	return append([]byte(nil), keys.clientToServer[:]...), responseTestKeys{
		aead:         append([]byte(nil), keys.serverToClientAEAD[:]...),
		confirmation: append([]byte(nil), keys.serverToClientConfirmation[:]...),
	}
}

func assertCompletionResponseDecrypts(
	t *testing.T,
	result CompletionResult,
	responseKeys responseTestKeys,
) completionResponseWire {
	t.Helper()
	block, err := aes.NewCipher(responseKeys.aead)
	if err != nil {
		t.Fatalf("response cipher: %v", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatalf("response AEAD: %v", err)
	}
	plaintext, err := aead.Open(
		nil,
		result.Nonce[:],
		result.Ciphertext,
		completionResponseAAD(result.DeviceID),
	)
	if err != nil {
		t.Fatalf("decrypt response: %v", err)
	}
	var response completionResponseWire
	if err := json.Unmarshal(plaintext, &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.DeviceID == "" || response.KeyConfirmation == "" {
		t.Fatal("completion response omitted key confirmation")
	}
	if decodedToken, decodeErr := base64.RawURLEncoding.DecodeString(response.PairingStatusToken); decodeErr != nil || len(decodedToken) != SecretSize {
		t.Fatal("completion response omitted the fixed-size pairing status bearer")
	}
	decodedConfirmation, err := base64.RawURLEncoding.DecodeString(response.KeyConfirmation)
	if err != nil {
		t.Fatalf("decode key confirmation: %v", err)
	}
	expectedConfirmation := hmac.New(sha256.New, responseKeys.confirmation)
	_, _ = expectedConfirmation.Write(completionResponseAAD(result.DeviceID))
	if !hmac.Equal(decodedConfirmation, expectedConfirmation.Sum(nil)) {
		t.Fatal("completion response key confirmation used the wrong key")
	}
	if response.Status != string(CompletionPendingConfirmation) {
		t.Fatalf("completion response status: got %q", response.Status)
	}
	var fields map[string]any
	if err := json.Unmarshal(plaintext, &fields); err != nil {
		t.Fatalf("decode response fields: %v", err)
	}
	if _, exists := fields["install_root"]; exists {
		t.Fatal("completion response transmitted the install root")
	}
	if _, exists := fields["device_secret"]; exists {
		t.Fatal("completion response transmitted a device secret")
	}
	return response
}

type serviceFixture struct {
	clock        *fixedClock
	identity     testIdentity
	keyProtector *authenticatedTestKeyProtector
	repository   *memoryRepository
	service      *Service
}

func verifiedAdmin(t *testing.T, tenantID TenantID) VerifiedAdminPrincipal {
	t.Helper()
	principal, err := NewVerifiedAdminPrincipal("admin-001", tenantID)
	if err != nil {
		t.Fatalf("verified admin principal: %v", err)
	}
	return principal
}

func confirmationRequestID(marker byte) ConfirmationRequestID {
	var requestID ConfirmationRequestID
	requestID[0] = marker
	return requestID
}

func newServiceFixture(t *testing.T) serviceFixture {
	t.Helper()

	seed := sha256.Sum256([]byte("openpaycongo-test-identity"))
	privateKey := ed25519.NewKeyFromSeed(seed[:])
	identity := testIdentity{
		privateKey: privateKey,
		publicKey:  privateKey.Public().(ed25519.PublicKey),
	}
	clock := &fixedClock{now: time.Date(2026, 8, 10, 9, 30, 0, 0, time.UTC)}
	keyProtector := &authenticatedTestKeyProtector{}
	repository := newMemoryRepository()
	service, err := NewService(ServiceOptions{
		Clock:         clock,
		Endpoint:      "https://pairing.example.test/v1/pairing/complete",
		EnrollmentTTL: 2 * time.Minute,
		Identity:      identity,
		KeyProtector:  keyProtector,
		MaxAttempts:   3,
		Random:        newDeterministicReader("openpaycongo-pairing"),
		Repository:    repository,
		TrustMode:     EnrollmentTrustPinnedContinuity,
	})
	if err != nil {
		t.Fatalf("new service: %v", err)
	}
	return serviceFixture{
		clock:        clock,
		identity:     identity,
		keyProtector: keyProtector,
		repository:   repository,
		service:      service,
	}
}

type fixedClock struct {
	now time.Time
}

func (clock *fixedClock) Now() time.Time {
	return clock.now
}

type deterministicReader struct {
	counter uint64
	mu      sync.Mutex
	seed    string
}

func newDeterministicReader(seed string) *deterministicReader {
	return &deterministicReader{seed: seed}
}

func (reader *deterministicReader) Read(target []byte) (int, error) {
	reader.mu.Lock()
	defer reader.mu.Unlock()

	written := 0
	for written < len(target) {
		counterBytes := make([]byte, 8)
		binary.BigEndian.PutUint64(counterBytes, reader.counter)
		block := sha256.Sum256(append([]byte(reader.seed), counterBytes...))
		reader.counter++
		written += copy(target[written:], block[:])
	}
	return len(target), nil
}

type testIdentity struct {
	privateKey ed25519.PrivateKey
	publicKey  ed25519.PublicKey
}

type countingTrustStore struct {
	fingerprint EnrollmentSigningFingerprint
	lookups     int
}

func (store *countingTrustStore) PinState(
	_ context.Context,
	fingerprint EnrollmentSigningFingerprint,
) (EnrollmentPinState, error) {
	store.lookups++
	if store.fingerprint == (EnrollmentSigningFingerprint{}) {
		return EnrollmentPinAbsent, nil
	}
	if fingerprint == store.fingerprint {
		return EnrollmentPinMatches, nil
	}
	return EnrollmentPinDiffers, nil
}

func (identity testIdentity) PublicKey() ed25519.PublicKey {
	return append(ed25519.PublicKey(nil), identity.publicKey...)
}

func (identity testIdentity) Sign(message []byte) (Signature, error) {
	var signature Signature
	copy(signature[:], ed25519.Sign(identity.privateKey, message))
	return signature, nil
}

type authenticatedTestKeyProtector struct {
	nonceCount uint64
	mu         sync.Mutex
	unprotects int
}

type mismatchedIdentitySigner struct {
	publicKey  ed25519.PublicKey
	signingKey ed25519.PrivateKey
}

type commitFailureRepository struct {
	Repository
	abortContextWasLive bool
	abortErr            error
}

type commitThenErrorRepository struct {
	Repository
	abortCalls              int
	reconcileContextWasLive bool
}

func (repository *commitThenErrorRepository) FindCompletion(ctx context.Context, id PairingIntentID, digest RequestDigest) (CompletionResult, bool, error) {
	repository.reconcileContextWasLive = ctx.Err() == nil
	return repository.Repository.FindCompletion(ctx, id, digest)
}

func (repository *commitThenErrorRepository) Commit(ctx context.Context, commit CompletionCommit) (CommitOutcome, error) {
	_, err := repository.Repository.Commit(ctx, commit)
	if err != nil {
		return CommitOutcome{State: CommitNotCommitted}, err
	}
	return CommitOutcome{State: CommitUnknown}, errors.New("connection lost after commit")
}
func (repository *commitThenErrorRepository) AbortCompletion(ctx context.Context, id PairingIntentID, at time.Time) error {
	repository.abortCalls++
	return repository.Repository.AbortCompletion(ctx, id, at)
}

func (*commitFailureRepository) Commit(context.Context, CompletionCommit) (CommitOutcome, error) {
	return CommitOutcome{State: CommitNotCommitted}, errors.New("commit unavailable before transaction")
}

func (repository *commitFailureRepository) AbortCompletion(
	ctx context.Context,
	id PairingIntentID,
	failedAt time.Time,
) error {
	repository.abortContextWasLive = ctx.Err() == nil
	if repository.abortErr != nil {
		return repository.abortErr
	}
	return repository.Repository.AbortCompletion(ctx, id, failedAt)
}

func (signer mismatchedIdentitySigner) PublicKey() ed25519.PublicKey {
	return append(ed25519.PublicKey(nil), signer.publicKey...)
}

func (signer mismatchedIdentitySigner) Sign(message []byte) (Signature, error) {
	var signature Signature
	copy(signature[:], ed25519.Sign(signer.signingKey, message))
	return signature, nil
}

type zeroResultKeyProtector struct{}

type transientKeyProtector struct {
	delegate          KeyProtector
	protectFailures   uint8
	unprotectFailures uint8
}

type barrierRetryableKeyProtector struct {
	delegate      KeyProtector
	entered       chan struct{}
	failProtect   bool
	failUnprotect bool
	release       chan struct{}
}

func (protector *barrierRetryableKeyProtector) Protect(
	ctx context.Context,
	plaintext SecretMaterial,
	aad ProtectionAAD,
) (ProtectedMaterial, error) {
	if !protector.failProtect {
		return protector.delegate.Protect(ctx, plaintext, aad)
	}
	protector.entered <- struct{}{}
	<-protector.release
	return ProtectedMaterial{}, ErrKeyProtectorRetryable
}

func (protector *barrierRetryableKeyProtector) Unprotect(
	ctx context.Context,
	protected ProtectedMaterial,
	aad ProtectionAAD,
) (SecretMaterial, error) {
	if !protector.failUnprotect {
		return protector.delegate.Unprotect(ctx, protected, aad)
	}
	protector.entered <- struct{}{}
	<-protector.release
	return SecretMaterial{}, ErrKeyProtectorRetryable
}

func (protector *transientKeyProtector) Protect(ctx context.Context, plaintext SecretMaterial, aad ProtectionAAD) (ProtectedMaterial, error) {
	if protector.protectFailures > 0 {
		protector.protectFailures--
		return ProtectedMaterial{}, ErrKeyProtectorRetryable
	}
	return protector.delegate.Protect(ctx, plaintext, aad)
}
func (protector *transientKeyProtector) Unprotect(ctx context.Context, protected ProtectedMaterial, aad ProtectionAAD) (SecretMaterial, error) {
	if protector.unprotectFailures > 0 {
		protector.unprotectFailures--
		return SecretMaterial{}, ErrKeyProtectorRetryable
	}
	return protector.delegate.Unprotect(ctx, protected, aad)
}

func (zeroResultKeyProtector) Protect(
	context.Context,
	SecretMaterial,
	ProtectionAAD,
) (ProtectedMaterial, error) {
	return ProtectedMaterial{}, nil
}

func (zeroResultKeyProtector) Unprotect(
	context.Context,
	ProtectedMaterial,
	ProtectionAAD,
) (SecretMaterial, error) {
	return SecretMaterial{}, errors.New("zero-result protector cannot unprotect")
}

func (protector *authenticatedTestKeyProtector) Protect(
	_ context.Context,
	plaintext SecretMaterial,
	aad ProtectionAAD,
) (ProtectedMaterial, error) {
	associatedData := aad.Bytes()
	key := sha256.Sum256([]byte("openpaycongo/test-key-protector/v1"))
	block, err := aes.NewCipher(key[:])
	if err != nil {
		return ProtectedMaterial{}, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return ProtectedMaterial{}, err
	}
	protector.mu.Lock()
	protector.nonceCount++
	nonceCount := protector.nonceCount
	protector.mu.Unlock()
	nonceInput := append(append([]byte(nil), associatedData...), plaintext[:]...)
	var nonceCounter [8]byte
	binary.BigEndian.PutUint64(nonceCounter[:], nonceCount)
	nonceInput = append(nonceInput, nonceCounter[:]...)
	nonceDigest := sha256.Sum256(nonceInput)
	nonce := nonceDigest[:aead.NonceSize()]
	protected := make([]byte, 1, 1+len(nonce)+len(plaintext)+aead.Overhead())
	protected[0] = 1
	protected = append(protected, nonce...)
	protected = aead.Seal(protected, nonce, plaintext[:], associatedData)
	return NewProtectedMaterial(protected)
}

func (protector *authenticatedTestKeyProtector) Unprotect(
	_ context.Context,
	protected ProtectedMaterial,
	aad ProtectionAAD,
) (SecretMaterial, error) {
	protector.mu.Lock()
	protector.unprotects++
	protector.mu.Unlock()
	protectedBytes := protected.Bytes()
	associatedData := aad.Bytes()
	key := sha256.Sum256([]byte("openpaycongo/test-key-protector/v1"))
	block, err := aes.NewCipher(key[:])
	if err != nil {
		return SecretMaterial{}, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return SecretMaterial{}, err
	}
	prefixLength := 1 + aead.NonceSize()
	if len(protectedBytes) < prefixLength+aead.Overhead() || protectedBytes[0] != 1 {
		return SecretMaterial{}, errors.Join(ErrKeyProtectorIntegrity, errors.New("invalid protected test material"))
	}
	nonce := protectedBytes[1:prefixLength]
	plaintext, err := aead.Open(nil, nonce, protectedBytes[prefixLength:], associatedData)
	if err != nil {
		return SecretMaterial{}, errors.Join(ErrKeyProtectorIntegrity, err)
	}
	if len(plaintext) != SecretSize {
		return SecretMaterial{}, errors.Join(ErrKeyProtectorIntegrity, errors.New("invalid protected test plaintext size"))
	}
	var secret SecretMaterial
	copy(secret[:], plaintext)
	wipe(plaintext)
	return secret, nil
}

func (protector *authenticatedTestKeyProtector) unprotectCount() int {
	protector.mu.Lock()
	defer protector.mu.Unlock()
	return protector.unprotects
}

type memoryRepository struct {
	acknowledgements map[PairingStatusTokenDigest]DeviceActivationStatus
	cleanupCursor    int
	mu               sync.Mutex
	order            []PairingIntentID
	records          map[PairingIntentID]memoryEnrollment
	reservationCount uint64
	devices          map[DeviceID]DeviceRecord
	installs         map[string]DeviceID
	statusTokens     map[PairingStatusTokenDigest]DeviceID
}

func newMemoryRepository() *memoryRepository {
	return &memoryRepository{
		acknowledgements: make(map[PairingStatusTokenDigest]DeviceActivationStatus),
		devices:          make(map[DeviceID]DeviceRecord),
		installs:         make(map[string]DeviceID),
		records:          make(map[PairingIntentID]memoryEnrollment),
		statusTokens:     make(map[PairingStatusTokenDigest]DeviceID),
	}
}

func (repository *memoryRepository) Create(
	_ context.Context,
	record PendingEnrollment,
) error {
	repository.mu.Lock()
	defer repository.mu.Unlock()
	if _, exists := repository.records[record.ID]; exists {
		return ErrIntentCollision
	}
	repository.records[record.ID] = memoryEnrollment{
		pending:      record,
		reservations: make(map[CompletionReservationID]struct{}),
	}
	repository.order = append(repository.order, record.ID)
	return nil
}

func (repository *memoryRepository) CleanupExpired(
	_ context.Context,
	before time.Time,
	limit uint16,
) (uint16, error) {
	repository.mu.Lock()
	defer repository.mu.Unlock()
	if limit == 0 || limit > CleanupPageSizeMax {
		return 0, ErrInvalidCleanupLimit
	}
	if repository.cleanupCursor >= len(repository.order) {
		repository.cleanupCursor = 0
	}
	var cleaned uint16
	var examined uint16
	for examined < limit && repository.cleanupCursor < len(repository.order) {
		id := repository.order[repository.cleanupCursor]
		repository.cleanupCursor++
		examined++
		record := repository.records[id]
		if before.Before(record.pending.ExpiresAt) {
			continue
		}
		changed := false
		if !record.pending.ProtectedServerPrivateKey.IsZero() {
			record.pending.ProtectedServerPrivateKey = ProtectedMaterial{}
			record.reservations = nil
			changed = true
		}
		if record.completed != nil && record.completed.Device.ActivationStatus == DevicePendingConfirmation {
			device := record.completed.Device
			device.ActivationStatus = DeviceExpired
			device.ProtectedInstallRoot = ProtectedMaterial{}
			device.ShortAuthenticationCode = ShortAuthenticationCode{}
			record.completed.Device = device
			repository.devices[device.ID] = device
			changed = true
		}
		if changed {
			repository.records[id] = record
			cleaned++
		}
	}
	return cleaned, nil
}

func (repository *memoryRepository) pendingEnrollment(id PairingIntentID) (PendingEnrollment, error) {
	repository.mu.Lock()
	defer repository.mu.Unlock()
	record, ok := repository.records[id]
	if !ok {
		return PendingEnrollment{}, ErrEnrollmentUnavailable
	}
	return record.pending, nil
}

func (repository *memoryRepository) tamperProtectedIntent(t *testing.T, id PairingIntentID) {
	t.Helper()
	repository.mu.Lock()
	defer repository.mu.Unlock()
	record := repository.records[id]
	protected := record.pending.ProtectedServerPrivateKey.Bytes()
	protected[len(protected)-1] ^= 1
	material, err := NewProtectedMaterial(protected)
	if err != nil {
		t.Fatalf("tamper material: %v", err)
	}
	record.pending.ProtectedServerPrivateKey = material
	repository.records[id] = record
}

func (repository *memoryRepository) FindCompletion(
	_ context.Context,
	id PairingIntentID,
	requestDigest RequestDigest,
) (CompletionResult, bool, error) {
	repository.mu.Lock()
	defer repository.mu.Unlock()
	record, ok := repository.records[id]
	if !ok || record.completed == nil {
		return CompletionResult{}, false, nil
	}
	if record.completed.RequestDigest != requestDigest {
		return CompletionResult{}, false, ErrEnrollmentUnavailable
	}
	result := record.completed.Result
	result.Status = CompletionReplayed
	return result, true, nil
}

func (repository *memoryRepository) BeginCompletionAttempt(
	_ context.Context,
	id PairingIntentID,
	now time.Time,
	maxAttempts uint8,
	maxInFlight uint8,
) (CompletionReservation, error) {
	repository.mu.Lock()
	defer repository.mu.Unlock()
	record, ok := repository.records[id]
	if !ok || record.completed != nil || record.aborted {
		return CompletionReservation{}, ErrEnrollmentUnavailable
	}
	if !now.Before(record.pending.ExpiresAt) || record.pending.InvalidProofAttempts >= maxAttempts {
		record.pending.ProtectedServerPrivateKey = ProtectedMaterial{}
		record.reservations = nil
		record.aborted = true
		repository.records[id] = record
		return CompletionReservation{}, ErrEnrollmentUnavailable
	}
	if maxInFlight == 0 || maxInFlight > CompletionReservationsMax || len(record.reservations) >= int(maxInFlight) {
		return CompletionReservation{}, ErrEnrollmentUnavailable
	}
	repository.reservationCount++
	var reservationID CompletionReservationID
	binary.BigEndian.PutUint64(reservationID[CompletionReservationIDSize-8:], repository.reservationCount)
	record.reservations[reservationID] = struct{}{}
	repository.records[id] = record
	return CompletionReservation{Enrollment: record.pending, ID: reservationID}, nil
}

func (repository *memoryRepository) ReleaseCompletionAttempt(
	ctx context.Context,
	id PairingIntentID,
	reservationID CompletionReservationID,
) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	repository.mu.Lock()
	defer repository.mu.Unlock()
	record, ok := repository.records[id]
	if !ok {
		return ErrEnrollmentUnavailable
	}
	if record.completed != nil || record.aborted {
		return nil
	}
	delete(record.reservations, reservationID)
	repository.records[id] = record
	return nil
}

func (repository *memoryRepository) AbortCompletion(
	ctx context.Context,
	id PairingIntentID,
	_ time.Time,
) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	repository.mu.Lock()
	defer repository.mu.Unlock()
	record, ok := repository.records[id]
	if !ok || record.completed != nil {
		return ErrEnrollmentUnavailable
	}
	record.pending.ProtectedServerPrivateKey = ProtectedMaterial{}
	record.reservations = nil
	record.aborted = true
	repository.records[id] = record
	return nil
}

func (repository *memoryRepository) FinishFailedCompletion(
	_ context.Context,
	id PairingIntentID,
	reservationID CompletionReservationID,
	failedAt time.Time,
	maxAttempts uint8,
) error {
	repository.mu.Lock()
	defer repository.mu.Unlock()
	record, ok := repository.records[id]
	if !ok {
		return ErrEnrollmentUnavailable
	}
	if record.completed != nil || record.aborted {
		return nil
	}
	if _, reserved := record.reservations[reservationID]; !reserved {
		return nil
	}
	delete(record.reservations, reservationID)
	if record.pending.InvalidProofAttempts < maxAttempts {
		record.pending.InvalidProofAttempts++
	}
	if !failedAt.Before(record.pending.ExpiresAt) || record.pending.InvalidProofAttempts >= maxAttempts {
		record.pending.ProtectedServerPrivateKey = ProtectedMaterial{}
		record.reservations = nil
		record.aborted = true
	}
	repository.records[id] = record
	return nil
}

func (repository *memoryRepository) GetConfirmation(
	_ context.Context,
	actor VerifiedAdminPrincipal,
	id PairingIntentID,
	now time.Time,
) (PairingConfirmationView, error) {
	repository.mu.Lock()
	defer repository.mu.Unlock()
	record, ok := repository.records[id]
	if !ok || record.completed == nil {
		return PairingConfirmationView{}, ErrEnrollmentUnavailable
	}
	device := record.completed.Device
	if device.TenantID != actor.TenantID() {
		return PairingConfirmationView{}, ErrEnrollmentUnavailable
	}
	if device.ActivationStatus == DevicePendingConfirmation && !now.Before(record.pending.ExpiresAt) {
		device.ActivationStatus = DeviceExpired
		device.ProtectedInstallRoot = ProtectedMaterial{}
		device.ShortAuthenticationCode = ShortAuthenticationCode{}
		record.completed.Device = device
		repository.devices[device.ID] = device
		repository.records[id] = record
	}
	view := PairingConfirmationView{
		ExpiresAt: record.pending.ExpiresAt,
		Status:    device.ActivationStatus,
	}
	if device.ActivationStatus == DevicePendingConfirmation {
		view.ShortAuthenticationCode = device.ShortAuthenticationCode
		view.IncludesShortAuthenticationCode = true
	}
	return view, nil
}

func (repository *memoryRepository) GetPhoneStatus(
	_ context.Context,
	tokenDigest PairingStatusTokenDigest,
) (PhonePairingStatusView, error) {
	repository.mu.Lock()
	defer repository.mu.Unlock()
	deviceID, ok := repository.statusTokens[tokenDigest]
	if !ok {
		return PhonePairingStatusView{}, ErrEnrollmentUnavailable
	}
	device, ok := repository.devices[deviceID]
	if !ok {
		return PhonePairingStatusView{}, ErrEnrollmentUnavailable
	}
	return PhonePairingStatusView{Status: device.ActivationStatus}, nil
}

func (repository *memoryRepository) AcknowledgePhoneStatus(
	_ context.Context,
	tokenDigest PairingStatusTokenDigest,
	status DeviceActivationStatus,
	_ time.Time,
) error {
	repository.mu.Lock()
	defer repository.mu.Unlock()
	deviceID, ok := repository.statusTokens[tokenDigest]
	if !ok {
		return ErrEnrollmentUnavailable
	}
	device, ok := repository.devices[deviceID]
	if !ok || device.ActivationStatus != status || status == DevicePendingConfirmation {
		return ErrEnrollmentUnavailable
	}
	if existing, acknowledged := repository.acknowledgements[tokenDigest]; acknowledged && existing != status {
		return ErrEnrollmentUnavailable
	}
	repository.acknowledgements[tokenDigest] = status
	return nil
}

func (repository *memoryRepository) Commit(
	_ context.Context,
	commit CompletionCommit,
) (CommitOutcome, error) {
	repository.mu.Lock()
	defer repository.mu.Unlock()
	record, ok := repository.records[commit.IntentID]
	if !ok {
		return CommitOutcome{State: CommitNotCommitted}, ErrEnrollmentUnavailable
	}
	if record.completed != nil {
		if record.completed.RequestDigest != commit.RequestDigest {
			return CommitOutcome{State: CommitNotCommitted}, ErrEnrollmentUnavailable
		}
		result := record.completed.Result
		result.Status = CompletionReplayed
		return CommitOutcome{State: CommitCommitted, Result: result}, nil
	}
	if !commit.CompletedAt.Before(record.pending.ExpiresAt) {
		return CommitOutcome{State: CommitNotCommitted}, ErrEnrollmentUnavailable
	}
	if record.pending.InvalidProofAttempts >= commit.MaxAttempts {
		return CommitOutcome{State: CommitNotCommitted}, ErrEnrollmentUnavailable
	}
	if _, reserved := record.reservations[commit.ReservationID]; !reserved {
		return CommitOutcome{State: CommitNotCommitted}, ErrEnrollmentUnavailable
	}
	if _, exists := repository.devices[commit.Device.ID]; exists {
		return CommitOutcome{State: CommitNotCommitted}, ErrEnrollmentUnavailable
	}
	installKey := commit.Device.TenantID.String() + "\x00" + commit.Device.InstallID
	if _, exists := repository.installs[installKey]; exists {
		return CommitOutcome{State: CommitNotCommitted}, ErrEnrollmentUnavailable
	}
	repository.devices[commit.Device.ID] = commit.Device
	repository.statusTokens[commit.Device.PairingStatusTokenDigest] = commit.Device.ID
	repository.installs[installKey] = commit.Device.ID
	record.completed = &commit
	record.pending.ProtectedServerPrivateKey = ProtectedMaterial{}
	record.reservations = nil
	repository.records[commit.IntentID] = record
	return CommitOutcome{State: CommitCommitted, Result: commit.Result}, nil
}

func (repository *memoryRepository) Confirm(
	_ context.Context,
	command ConfirmationCommand,
) (DeviceActivationStatus, error) {
	repository.mu.Lock()
	defer repository.mu.Unlock()
	record, ok := repository.records[command.IntentID]
	if !ok || record.completed == nil {
		return "", ErrEnrollmentUnavailable
	}
	device := record.completed.Device
	if device.TenantID != command.Actor.TenantID() {
		return "", ErrEnrollmentUnavailable
	}
	if record.confirmation != nil {
		existing := *record.confirmation
		exactReplay := existing.Actor == command.Actor && existing.RequestID == command.RequestID &&
			existing.Decision == command.Decision && existing.Reason == command.Reason
		if !exactReplay {
			return "", ErrConfirmationConflict
		}
		return device.ActivationStatus, nil
	}
	if device.ActivationStatus != DevicePendingConfirmation {
		return "", ErrConfirmationConflict
	}
	if !command.ConfirmedAt.Before(record.pending.ExpiresAt) {
		device.ActivationStatus = DeviceExpired
		device.ProtectedInstallRoot = ProtectedMaterial{}
		device.ShortAuthenticationCode = ShortAuthenticationCode{}
		repository.devices[device.ID] = device
		record.completed.Device = device
		terminal := command
		record.confirmation = &terminal
		repository.records[command.IntentID] = record
		return DeviceExpired, nil
	}
	if command.Decision == ConfirmationCodesMatch {
		device.ActivationStatus = DeviceActive
	} else {
		device.ActivationStatus = DeviceRevoked
		device.ProtectedInstallRoot = ProtectedMaterial{}
	}
	device.ShortAuthenticationCode = ShortAuthenticationCode{}
	repository.devices[device.ID] = device
	record.completed.Device = device
	terminal := command
	record.confirmation = &terminal
	repository.records[command.IntentID] = record
	return device.ActivationStatus, nil
}

func (repository *memoryRepository) confirmationAudit(
	id PairingIntentID,
) (ConfirmationCommand, error) {
	repository.mu.Lock()
	defer repository.mu.Unlock()
	record, ok := repository.records[id]
	if !ok || record.confirmation == nil {
		return ConfirmationCommand{}, ErrEnrollmentUnavailable
	}
	return *record.confirmation, nil
}

func (repository *memoryRepository) deviceCount() int {
	repository.mu.Lock()
	defer repository.mu.Unlock()
	return len(repository.devices)
}

func (repository *memoryRepository) pendingCount() int {
	repository.mu.Lock()
	defer repository.mu.Unlock()
	return len(repository.records)
}

func (repository *memoryRepository) inFlightReservationCount(id PairingIntentID) int {
	repository.mu.Lock()
	defer repository.mu.Unlock()
	return len(repository.records[id].reservations)
}

func (repository *memoryRepository) onlyDevice(t *testing.T) DeviceRecord {
	t.Helper()
	repository.mu.Lock()
	defer repository.mu.Unlock()
	if len(repository.devices) != 1 {
		t.Fatalf("devices: got %d", len(repository.devices))
	}
	for _, device := range repository.devices {
		return device
	}
	panic("unreachable")
}

type memoryEnrollment struct {
	aborted      bool
	completed    *CompletionCommit
	confirmation *ConfirmationCommand
	pending      PendingEnrollment
	reservations map[CompletionReservationID]struct{}
}

var _ Repository = (*memoryRepository)(nil)
var _ = errors.Is
