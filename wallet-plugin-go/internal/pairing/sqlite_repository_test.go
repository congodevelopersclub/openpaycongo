package pairing

import (
	"bytes"
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"
)

func TestSQLiteRepositoryPersistsPairingLifecycleAcrossRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "pairing.db")
	repository, err := OpenSQLiteRepository(path)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	now := time.Date(2026, 8, 15, 12, 0, 0, 0, time.UTC)
	pending := sqlitePendingEnrollment(t, 1, now.Add(time.Minute))
	if err := repository.Create(ctx, pending); err != nil {
		t.Fatal(err)
	}
	reservation, err := repository.BeginCompletionAttempt(ctx, pending.ID, now, 3, 2)
	if err != nil {
		t.Fatal(err)
	}
	commit := sqliteCommit(t, pending, reservation.ID, now)
	if outcome, err := repository.Commit(ctx, commit); err != nil || outcome.State != CommitCommitted {
		t.Fatalf("commit: %#v %v", outcome, err)
	}
	if err := repository.Close(); err != nil {
		t.Fatal(err)
	}

	repository, err = OpenSQLiteRepository(path)
	if err != nil {
		t.Fatal(err)
	}
	defer repository.Close()
	replayed, found, err := repository.FindCompletion(ctx, pending.ID, commit.RequestDigest)
	if err != nil || !found || replayed.DeviceID != commit.Result.DeviceID || replayed.Nonce != commit.Result.Nonce || replayed.Status != commit.Result.Status || !bytes.Equal(replayed.Ciphertext, commit.Result.Ciphertext) {
		t.Fatalf("replay: %#v %v %v", replayed, found, err)
	}
	status, err := repository.Confirm(ctx, sqliteConfirmation(t, pending, now.Add(time.Second), ConfirmationCodesMatch))
	if err != nil || status != DeviceActive {
		t.Fatalf("confirm: %q %v", status, err)
	}
	if err := repository.AcknowledgePhoneStatus(ctx, commit.Device.PairingStatusTokenDigest, DeviceActive, now.Add(2*time.Second)); err != nil {
		t.Fatal(err)
	}
	phone, err := repository.GetPhoneStatus(ctx, commit.Device.PairingStatusTokenDigest)
	if err != nil || phone.Status != DeviceActive {
		t.Fatalf("phone: %#v %v", phone, err)
	}
}

func TestSQLiteRepositoryEnforcesTerminalAndReplayInvariants(t *testing.T) {
	repository, err := OpenSQLiteRepository(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer repository.Close()
	ctx := context.Background()
	now := time.Date(2026, 8, 15, 12, 0, 0, 0, time.UTC)
	pending := sqlitePendingEnrollment(t, 2, now.Add(time.Minute))
	if err := repository.Create(ctx, pending); err != nil {
		t.Fatal(err)
	}
	if err := repository.Create(ctx, pending); !errors.Is(err, ErrIntentCollision) {
		t.Fatalf("duplicate: %v", err)
	}
	first, err := repository.BeginCompletionAttempt(ctx, pending.ID, now, 2, 1)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := repository.BeginCompletionAttempt(ctx, pending.ID, now, 2, 1); !errors.Is(err, ErrEnrollmentUnavailable) {
		t.Fatalf("in flight: %v", err)
	}
	if err := repository.FinishFailedCompletion(ctx, pending.ID, first.ID, now, 2); err != nil {
		t.Fatal(err)
	}
	second, err := repository.BeginCompletionAttempt(ctx, pending.ID, now, 2, 1)
	if err != nil {
		t.Fatal(err)
	}
	commit := sqliteCommit(t, pending, second.ID, now)
	if _, err := repository.Commit(ctx, commit); err != nil {
		t.Fatal(err)
	}
	command := sqliteConfirmation(t, pending, now.Add(time.Second), ConfirmationCodesMismatch)
	if status, err := repository.Confirm(ctx, command); err != nil || status != DeviceRevoked {
		t.Fatalf("mismatch: %q %v", status, err)
	}
	if status, err := repository.Confirm(ctx, command); err != nil || status != DeviceRevoked {
		t.Fatalf("replay confirmation: %q %v", status, err)
	}
	command.RequestID[0]++
	if _, err := repository.Confirm(ctx, command); !errors.Is(err, ErrConfirmationConflict) {
		t.Fatalf("terminal conflict: %v", err)
	}
	if err := repository.AcknowledgePhoneStatus(ctx, commit.Device.PairingStatusTokenDigest, DevicePendingConfirmation, now); !errors.Is(err, ErrEnrollmentUnavailable) {
		t.Fatalf("pending ack: %v", err)
	}
}

func sqlitePendingEnrollment(t *testing.T, seed byte, expiresAt time.Time) PendingEnrollment {
	t.Helper()
	protected, err := NewProtectedMaterial([]byte{seed, 9, 8})
	if err != nil {
		t.Fatal(err)
	}
	tenant, err := ParseTenantID("tenant-sqlite")
	if err != nil {
		t.Fatal(err)
	}
	var id PairingIntentID
	id[0] = seed
	return PendingEnrollment{ID: id, TenantID: tenant, ExpiresAt: expiresAt, ProtectedServerPrivateKey: protected, TrustMode: EnrollmentTrustFirstUseRequiresSAS}
}

func sqliteCommit(t *testing.T, pending PendingEnrollment, reservation CompletionReservationID, now time.Time) CompletionCommit {
	t.Helper()
	root, err := NewProtectedMaterial([]byte{7, 8, pending.ID[0]})
	if err != nil {
		t.Fatal(err)
	}
	var deviceID DeviceID
	deviceID[0] = pending.ID[0]
	deviceID[1] = 1
	var digest RequestDigest
	digest[0] = pending.ID[0]
	var token PairingStatusTokenDigest
	token[0] = pending.ID[0]
	return CompletionCommit{IntentID: pending.ID, ReservationID: reservation, RequestDigest: digest, CompletedAt: now, MaxAttempts: 3,
		Result: CompletionResult{DeviceID: deviceID, Status: CompletionPendingConfirmation, Ciphertext: []byte{1, 2}, Nonce: Nonce{1}},
		Device: DeviceRecord{ID: deviceID, TenantID: pending.TenantID, InstallID: "install-" + string(rune(pending.ID[0])), ActivationStatus: DevicePendingConfirmation, ProtectedInstallRoot: root, PairingStatusTokenDigest: token, ShortAuthenticationCode: ShortAuthenticationCode{'1', '2', '3', '4', '5', '6'}},
	}
}

func sqliteConfirmation(t *testing.T, pending PendingEnrollment, now time.Time, decision ConfirmationDecision) ConfirmationCommand {
	t.Helper()
	actor, err := NewVerifiedAdminPrincipal("admin-sqlite", pending.TenantID)
	if err != nil {
		t.Fatal(err)
	}
	reason := ConfirmationReasonCodesComparedMatch
	if decision == ConfirmationCodesMismatch {
		reason = ConfirmationReasonCodesComparedMismatch
	}
	return ConfirmationCommand{IntentID: pending.ID, Actor: actor, ConfirmedAt: now, Decision: decision, Reason: reason, RequestID: ConfirmationRequestID{1}}
}
