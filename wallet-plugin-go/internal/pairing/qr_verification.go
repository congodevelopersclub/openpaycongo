package pairing

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"time"
)

func VerifyPairingQR(
	ctx context.Context,
	qr PairingQR,
	now time.Time,
	trustStore EnrollmentTrustStore,
	recoveryAuthorization LocalRecoveryAuthorization,
) error {
	if trustStore == nil || qr.Version != ProtocolVersion || qr.Algorithms != AlgorithmSuite {
		return ErrInvalidPairingQR
	}
	if err := validateEndpoint(qr.Endpoint); err != nil {
		return ErrInvalidPairingQR
	}
	_, offset := qr.ExpiresAt.Zone()
	if offset != 0 || qr.ExpiresAt.Nanosecond() != 0 {
		return ErrInvalidPairingQR
	}
	remaining := qr.ExpiresAt.Sub(now.UTC())
	if remaining <= 0 || remaining > EnrollmentTTLMax {
		return ErrInvalidPairingQR
	}

	fingerprint := sha256.Sum256(qr.EnrollmentSigningPublicKey[:])
	if fingerprint != qr.EnrollmentSigningFingerprint {
		return ErrInvalidPairingQR
	}
	if !ed25519.Verify(
		ed25519.PublicKey(qr.EnrollmentSigningPublicKey[:]),
		qrSigningTranscript(qr),
		qr.Signature[:],
	) {
		return ErrInvalidPairingQR
	}
	pinState, err := trustStore.PinState(ctx, qr.EnrollmentSigningFingerprint)
	if err != nil {
		return ErrUntrustedEnrollmentIdentity
	}
	if qr.TrustMode == EnrollmentTrustPinnedContinuity && pinState == EnrollmentPinMatches {
		return nil
	}
	if qr.TrustMode == EnrollmentTrustFirstUseRequiresSAS && pinState == EnrollmentPinAbsent && recoveryAuthorization.authenticated {
		return nil
	}
	if qr.TrustMode != EnrollmentTrustPinnedContinuity && qr.TrustMode != EnrollmentTrustFirstUseRequiresSAS {
		return ErrInvalidPairingQR
	}
	if pinState == EnrollmentPinDiffers || pinState == EnrollmentPinMatches || pinState == EnrollmentPinAbsent {
		return ErrUntrustedEnrollmentIdentity
	}
	return ErrUntrustedEnrollmentIdentity
}
