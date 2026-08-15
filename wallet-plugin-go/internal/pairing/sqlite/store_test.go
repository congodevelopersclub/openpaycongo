package sqlite

import (
	"context"
	"errors"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/example/wallet-plugin-go/internal/pairing"
)

func TestRepositoryLifecycleSurvivesRestartAndPreservesReplay(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "pairing.sqlite")
	store, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	now := time.Date(2026, 8, 15, 0, 0, 0, 0, time.UTC)
	p := testPending(t, 1, now.Add(time.Minute))
	if err := store.Create(ctx, p); err != nil {
		t.Fatal(err)
	}
	if err := store.Create(ctx, p); !errors.Is(err, pairing.ErrIntentCollision) {
		t.Fatalf("collision: %v", err)
	}
	r, err := store.BeginCompletionAttempt(ctx, p.ID, now, 3, 2)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.ReleaseCompletionAttempt(ctx, p.ID, r.ID); err != nil {
		t.Fatal(err)
	}
	if err := store.ReleaseCompletionAttempt(ctx, p.ID, r.ID); err != nil {
		t.Fatal(err)
	}
	r, err = store.BeginCompletionAttempt(ctx, p.ID, now, 3, 2)
	if err != nil {
		t.Fatal(err)
	}
	c := testCommit(t, p.ID, r.ID, now)
	out, err := store.Commit(ctx, c)
	if err != nil || out.State != pairing.CommitCommitted {
		t.Fatalf("commit: %#v %v", out, err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	replay, found, err := store.FindCompletion(ctx, p.ID, c.RequestDigest)
	if err != nil || !found || replay.Status != pairing.CompletionReplayed {
		t.Fatalf("replay: %#v %v %v", replay, found, err)
	}
	actor, _ := pairing.NewVerifiedAdminPrincipal("admin-1", c.Device.TenantID)
	view, err := store.GetConfirmation(ctx, actor, p.ID, now)
	if err != nil || !view.IncludesShortAuthenticationCode {
		t.Fatalf("confirmation view: %#v %v", view, err)
	}
	status, err := store.Confirm(ctx, pairing.ConfirmationCommand{Actor: actor, ConfirmedAt: now, Decision: pairing.ConfirmationCodesMatch, Reason: pairing.ConfirmationReasonCodesComparedMatch, IntentID: p.ID, RequestID: requestID(9)})
	if err != nil || status != pairing.DeviceActive {
		t.Fatalf("confirm: %q %v", status, err)
	}
	status, err = store.Confirm(ctx, pairing.ConfirmationCommand{Actor: actor, ConfirmedAt: now, Decision: pairing.ConfirmationCodesMatch, Reason: pairing.ConfirmationReasonCodesComparedMatch, IntentID: p.ID, RequestID: requestID(9)})
	if err != nil || status != pairing.DeviceActive {
		t.Fatalf("confirm replay: %q %v", status, err)
	}
	_, err = store.Confirm(ctx, pairing.ConfirmationCommand{Actor: actor, ConfirmedAt: now, Decision: pairing.ConfirmationCodesMismatch, Reason: pairing.ConfirmationReasonCodesComparedMismatch, IntentID: p.ID, RequestID: requestID(8)})
	if !errors.Is(err, pairing.ErrConfirmationConflict) {
		t.Fatalf("confirmation conflict: %v", err)
	}
	phone, err := store.GetPhoneStatus(ctx, c.Device.PairingStatusTokenDigest)
	if err != nil || phone.Status != pairing.DeviceActive {
		t.Fatalf("phone: %#v %v", phone, err)
	}
	if err := store.AcknowledgePhoneStatus(ctx, c.Device.PairingStatusTokenDigest, pairing.DeviceActive, now); err != nil {
		t.Fatal(err)
	}
	if err := store.AcknowledgePhoneStatus(ctx, c.Device.PairingStatusTokenDigest, pairing.DeviceActive, now); err != nil {
		t.Fatal(err)
	}
	if err := store.AcknowledgePhoneStatus(ctx, c.Device.PairingStatusTokenDigest, pairing.DeviceRevoked, now); !errors.Is(err, pairing.ErrEnrollmentUnavailable) {
		t.Fatalf("contradictory ack: %v", err)
	}
}

func TestRepositoryBoundsExpiryFailureAndConcurrentReservation(t *testing.T) {
	t.Parallel()
	store, err := Open(filepath.Join(t.TempDir(), "pairing.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	ctx := context.Background()
	now := time.Now().UTC()
	p := testPending(t, 2, now.Add(time.Minute))
	if err := store.Create(ctx, p); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	var mu sync.Mutex
	reservations := make([]pairing.CompletionReservationID, 0, 2)
	for range 12 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r, e := store.BeginCompletionAttempt(ctx, p.ID, now, 2, 2)
			if e == nil {
				mu.Lock()
				reservations = append(reservations, r.ID)
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if len(reservations) != 2 {
		t.Fatalf("in-flight bound violated: %d", len(reservations))
	}
	for _, reservation := range reservations {
		if err := store.FinishFailedCompletion(ctx, p.ID, reservation, now, 2); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := store.BeginCompletionAttempt(ctx, p.ID, now, 2, 2); !errors.Is(err, pairing.ErrEnrollmentUnavailable) {
		t.Fatalf("exhaustion: %v", err)
	}
	expired := testPending(t, 3, now)
	if err := store.Create(ctx, expired); err != nil {
		t.Fatal(err)
	}
	if n, e := store.CleanupExpired(ctx, now, 2); e != nil || n != 1 {
		t.Fatalf("bounded cleanup: %d %v", n, e)
	}
	if _, e := store.BeginCompletionAttempt(ctx, expired.ID, now, 2, 1); !errors.Is(e, pairing.ErrEnrollmentUnavailable) {
		t.Fatalf("expired begin: %v", e)
	}
	if err := store.AbortCompletion(ctx, expired.ID, now); err != nil {
		t.Fatal(err)
	}
}

func testPending(t *testing.T, seed byte, expires time.Time) pairing.PendingEnrollment {
	t.Helper()
	tenant, _ := pairing.ParseTenantID("tenant-demo")
	material, _ := pairing.NewProtectedMaterial(make([]byte, 32))
	var id pairing.PairingIntentID
	id[0] = seed
	var nonce pairing.IntentNonce
	nonce[0] = seed
	var fp pairing.EnrollmentSigningFingerprint
	fp[0] = seed
	var pub pairing.ServerKeyAgreementPublic
	pub[0] = seed
	return pairing.PendingEnrollment{ExpiresAt: expires, ID: id, IntentNonce: nonce, ProtectedServerPrivateKey: material, EnrollmentSigningFingerprint: fp, ServerKeyAgreementPublic: pub, TenantID: tenant, TrustMode: pairing.EnrollmentTrustFirstUseRequiresSAS}
}
func testCommit(t *testing.T, id pairing.PairingIntentID, rid pairing.CompletionReservationID, now time.Time) pairing.CompletionCommit {
	t.Helper()
	tenant, _ := pairing.ParseTenantID("tenant-demo")
	root, _ := pairing.NewProtectedMaterial(make([]byte, 32))
	var did pairing.DeviceID
	did[0] = 4
	var token pairing.PairingStatusTokenDigest
	token[0] = 5
	var signing pairing.DeviceSigningPublicKey
	signing[0] = 6
	var digest pairing.RequestDigest
	digest[0] = 7
	var nonce pairing.Nonce
	nonce[0] = 8
	var code pairing.ShortAuthenticationCode
	copy(code[:], "123456")
	return pairing.CompletionCommit{CompletedAt: now, IntentID: id, ReservationID: rid, RequestDigest: digest, MaxAttempts: 3, Result: pairing.CompletionResult{Ciphertext: []byte("response"), DeviceID: did, Nonce: nonce, Status: pairing.CompletionPendingConfirmation}, Device: pairing.DeviceRecord{ActivationStatus: pairing.DevicePendingConfirmation, DeviceSigningPublicKey: signing, ID: did, InstallID: "install-1", ProtectedInstallRoot: root, PairingStatusTokenDigest: token, ShortAuthenticationCode: code, TenantID: tenant}}
}
func requestID(seed byte) pairing.ConfirmationRequestID {
	var id pairing.ConfirmationRequestID
	id[0] = seed
	return id
}
