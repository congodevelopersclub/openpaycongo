package syncapp

import (
	"context"
	"crypto/sha256"
	"errors"
	"testing"
	"time"

	"github.com/example/wallet-plugin-go/internal/analytics"
)

type pairingFake struct {
	active bool
	calls  int
}

func (fake *pairingFake) IsActive(context.Context, string, string) (bool, error) {
	fake.calls++
	return fake.active, nil
}

type ingestFake struct {
	appendCalls, acknowledgementCalls int
	events                            map[string]analytics.LedgerEvent
	ack                               uint64
}

func (fake *ingestFake) Append(_ context.Context, event analytics.LedgerEvent) (AppendResult, error) {
	fake.appendCalls++
	if existing, found := fake.events[event.ID]; found {
		if existing != event {
			return AppendResult{}, analytics.ErrEventConflict
		}
		return AppendResult{Replayed: true}, nil
	}
	fake.events[event.ID] = event
	return AppendResult{}, nil
}
func (fake *ingestFake) Acknowledge(_ context.Context, _ string, _ string, cursor uint64) (AcknowledgementResult, error) {
	fake.acknowledgementCalls++
	if cursor == fake.ack {
		return AcknowledgementResult{Replayed: true}, nil
	}
	if cursor != fake.ack+1 {
		return AcknowledgementResult{}, analytics.ErrEventConflict
	}
	fake.ack = cursor
	return AcknowledgementResult{}, nil
}

func event(t *testing.T, id, paymentID string) analytics.LedgerEvent {
	t.Helper()
	now := time.Date(2026, 8, 15, 0, 0, 0, 0, time.UTC)
	input := analytics.EventInput{ID: id, TenantID: "tenant-demo", Kind: analytics.KindCapture, Amount: "1250", Currency: "USD", Provider: "MOBILEMONEY", PaymentID: paymentID, OccurredAt: now, ReceivedAt: now, Digest: sha256.Sum256([]byte(id))}
	digest, err := analytics.CanonicalEventDigest(input)
	if err != nil {
		t.Fatal(err)
	}
	input.Digest = digest
	value, err := analytics.NewLedgerEvent(input)
	if err != nil {
		t.Fatal(err)
	}
	return value
}

func fixture(t *testing.T) (Service, Principal, Batch, *pairingFake, *ingestFake) {
	t.Helper()
	principal, err := NewPrincipal("tenant-demo", "device-demo", "subject-demo", []string{ScopeWrite})
	if err != nil {
		t.Fatal(err)
	}
	batch, err := NewBatch("tenant-demo", "device-demo", []analytics.LedgerEvent{event(t, "018f0000-0000-7000-8000-000000000001", "PAY-1234")}, 1)
	if err != nil {
		t.Fatal(err)
	}
	pairing, ingest := &pairingFake{active: true}, &ingestFake{events: map[string]analytics.LedgerEvent{}}
	return New(pairing, ingest), principal, batch, pairing, ingest
}

func TestApplyReturnsExactReplayAndContiguousAcknowledgementResult(t *testing.T) {
	service, principal, batch, _, _ := fixture(t)
	first, err := service.Apply(context.Background(), principal, batch)
	if err != nil || first.EventsReplayed || first.AcknowledgementReplayed || first.AcknowledgedCursor != 1 {
		t.Fatalf("first=%#v err=%v", first, err)
	}
	second, err := service.Apply(context.Background(), principal, batch)
	if err != nil || !second.EventsReplayed || !second.AcknowledgementReplayed {
		t.Fatalf("replay=%#v err=%v", second, err)
	}
}

func TestApplyRejectsAuthorizationBeforeEitherRepositoryPort(t *testing.T) {
	service, principal, batch, pairing, ingest := fixture(t)
	principal.Scopes = nil
	if _, err := service.Apply(context.Background(), principal, batch); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("scope=%v", err)
	}
	if pairing.calls != 0 || ingest.appendCalls != 0 || ingest.acknowledgementCalls != 0 {
		t.Fatalf("calls pairing=%d append=%d ack=%d", pairing.calls, ingest.appendCalls, ingest.acknowledgementCalls)
	}
	principal, _ = NewPrincipal("other-tenant", "device-demo", "subject-demo", []string{ScopeWrite})
	if _, err := service.Apply(context.Background(), principal, batch); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("tenant=%v", err)
	}
	if pairing.calls != 0 || ingest.appendCalls != 0 || ingest.acknowledgementCalls != 0 {
		t.Fatal("mismatched principal touched repository")
	}
	principal, _ = NewPrincipal("tenant-demo", "other-device", "subject-demo", []string{ScopeWrite})
	if _, err := service.Apply(context.Background(), principal, batch); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("device=%v", err)
	}
	if pairing.calls != 0 || ingest.appendCalls != 0 || ingest.acknowledgementCalls != 0 {
		t.Fatal("mismatched device touched repository")
	}
}

func TestApplyRejectsConflictingReplayAndKeepsAckUntouched(t *testing.T) {
	service, principal, batch, _, ingest := fixture(t)
	if _, err := service.Apply(context.Background(), principal, batch); err != nil {
		t.Fatal(err)
	}
	changed := event(t, "018f0000-0000-7000-8000-000000000001", "PAY-9999")
	batch, err := NewBatch("tenant-demo", "device-demo", []analytics.LedgerEvent{changed}, 1)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := service.Apply(context.Background(), principal, batch); !errors.Is(err, analytics.ErrEventConflict) {
		t.Fatalf("conflict=%v", err)
	}
	if ingest.acknowledgementCalls != 1 {
		t.Fatalf("ack after conflict=%d", ingest.acknowledgementCalls)
	}
}

func TestApplyRejectsInactivePairingBeforeIngest(t *testing.T) {
	service, principal, batch, pairing, ingest := fixture(t)
	pairing.active = false
	if _, err := service.Apply(context.Background(), principal, batch); !errors.Is(err, ErrInactive) {
		t.Fatalf("inactive=%v", err)
	}
	if ingest.appendCalls != 0 || ingest.acknowledgementCalls != 0 {
		t.Fatal("inactive pairing ingested")
	}
}
