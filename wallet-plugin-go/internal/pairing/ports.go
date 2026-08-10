package pairing

import (
	"context"
	"crypto/ed25519"
	"io"
	"time"
)

type Clock interface {
	Now() time.Time
}

type IdentitySigner interface {
	PublicKey() ed25519.PublicKey
	Sign(message []byte) (Signature, error)
}

type EnrollmentTrustStore interface {
	PinState(ctx context.Context, fingerprint EnrollmentSigningFingerprint) (EnrollmentPinState, error)
}

type KeyProtector interface {
	// Protect must use an audited AEAD with a unique nonce, include a bounded
	// key identifier/version of at most ProtectedKeyIDLengthMax bytes and an
	// AEAD nonce of at most ProtectedNonceSizeMax bytes in the opaque result,
	// and bind the exact AAD. Dependency outages use ErrKeyProtectorRetryable;
	// permanent configuration/integrity failures use ErrKeyProtectorIntegrity.
	// A successful call must return non-zero material.
	Protect(ctx context.Context, plaintext SecretMaterial, aad ProtectionAAD) (ProtectedMaterial, error)
	// Unprotect fails closed for unknown key IDs, malformed/oversized material,
	// wrong AAD, or failed integrity using ErrKeyProtectorIntegrity. Dependency
	// outages use ErrKeyProtectorRetryable. It never returns partial plaintext.
	Unprotect(ctx context.Context, protected ProtectedMaterial, aad ProtectionAAD) (SecretMaterial, error)
}

type Repository interface {
	// CleanupExpired examines at most limit candidates, clears expired ephemeral
	// keys, expires pending devices, and preserves non-secret replay metadata.
	CleanupExpired(ctx context.Context, before time.Time, limit uint16) (uint16, error)
	// BeginCompletionAttempt atomically verifies pending/unexpired state and the
	// separate invalid-proof and in-flight bounds, then returns a unique opaque
	// reservation. Reserving does not consume an invalid-proof attempt.
	BeginCompletionAttempt(
		ctx context.Context,
		id PairingIntentID,
		now time.Time,
		maxAttempts uint8,
		maxInFlight uint8,
	) (CompletionReservation, error)
	// ReleaseCompletionAttempt atomically releases only the named reservation
	// after a retryable dependency failure. Repeated release is idempotent and
	// never changes invalid-proof accounting or revives terminal/completed state.
	ReleaseCompletionAttempt(
		ctx context.Context,
		id PairingIntentID,
		reservationID CompletionReservationID,
	) error
	// Commit atomically consumes one intent, uniquely creates tenant/install ID,
	// persists the protected root and pending-confirmation state, caches Result,
	// and clears the protected ephemeral private key while preserving replay metadata.
	Commit(ctx context.Context, commit CompletionCommit) (CommitOutcome, error)
	// Confirm authenticates tenant through Actor, records the first terminal
	// actor/request/reason/decision/time audit atomically, activates only match,
	// and destroys the protected root on mismatch/timeout. Exact command replay
	// is idempotent; every other terminal command conflicts.
	Confirm(ctx context.Context, command ConfirmationCommand) (DeviceActivationStatus, error)
	// Create is insert-only; duplicate intent IDs return ErrIntentCollision and
	// leave the original record unchanged.
	Create(ctx context.Context, enrollment PendingEnrollment) error
	FindCompletion(
		ctx context.Context,
		id PairingIntentID,
		requestDigest RequestDigest,
	) (CompletionResult, bool, error)
	GetConfirmation(
		ctx context.Context,
		actor VerifiedAdminPrincipal,
		id PairingIntentID,
		now time.Time,
	) (PairingConfirmationView, error)
	GetPhoneStatus(
		ctx context.Context,
		tokenDigest PairingStatusTokenDigest,
	) (PhonePairingStatusView, error)
	// AcknowledgePhoneStatus records that the phone learned an exact terminal
	// status. Exact repeats are idempotent; pending or contradictory acks fail.
	AcknowledgePhoneStatus(
		ctx context.Context,
		tokenDigest PairingStatusTokenDigest,
		status DeviceActivationStatus,
		acknowledgedAt time.Time,
	) error
	// FinishFailedCompletion atomically converts only the named in-flight
	// reservation into one completed invalid-proof attempt. Repeats are
	// idempotent; expiry or exhaustion clears the protected ephemeral key.
	FinishFailedCompletion(
		ctx context.Context,
		id PairingIntentID,
		reservationID CompletionReservationID,
		failedAt time.Time,
		maxAttempts uint8,
	) error
	// AbortCompletion atomically makes a known-uncommitted intent terminal and
	// clears its protected ephemeral key. It is forbidden for CommitUnknown.
	AbortCompletion(ctx context.Context, id PairingIntentID, failedAt time.Time) error
}

type ServiceOptions struct {
	Clock         Clock
	Endpoint      string
	EnrollmentTTL time.Duration
	Identity      IdentitySigner
	KeyProtector  KeyProtector
	MaxAttempts   uint8
	Random        io.Reader
	Repository    Repository
	TrustMode     EnrollmentTrustMode
}
