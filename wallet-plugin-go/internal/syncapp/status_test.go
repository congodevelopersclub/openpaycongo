package syncapp

import (
	"context"
	"errors"
	"testing"
	"time"
)

type statusClock struct{ now time.Time }

func (clock statusClock) Now() time.Time { return clock.now }

type statusReadFake struct {
	queueCalls, acknowledgementCalls, recoveryCalls int
	queue                                           QueueCounters
	ack                                             AcknowledgementMetadata
	recovery                                        RecoveryCounters
	err                                             error
}

func (fake *statusReadFake) ReadQueue(context.Context, string, string) (QueueCounters, error) {
	fake.queueCalls++
	return fake.queue, fake.err
}
func (fake *statusReadFake) ReadAcknowledgement(context.Context, string, string) (AcknowledgementMetadata, error) {
	fake.acknowledgementCalls++
	return fake.ack, fake.err
}
func (fake *statusReadFake) ReadRecovery(context.Context, string, string) (RecoveryCounters, error) {
	fake.recoveryCalls++
	return fake.recovery, fake.err
}

func statusFixture(t *testing.T) (StatusService, Principal, StatusRequest, *statusReadFake) {
	t.Helper()
	now := time.Date(2026, 8, 15, 0, 0, 0, 0, time.UTC)
	principal, err := NewPrincipal("tenant-demo", "device-demo", "subject-demo", []string{ScopeRead})
	if err != nil {
		t.Fatal(err)
	}
	request, err := NewStatusRequest("tenant-demo", "device-demo")
	if err != nil {
		t.Fatal(err)
	}
	read := &statusReadFake{queue: QueueCounters{Pending: 2, InFlight: 1, Failed: 3}, ack: AcknowledgementMetadata{Cursor: 8, AcceptedCount: 10}, recovery: RecoveryCounters{Prepared: 4, Applied: 3, Aborted: 1, UpdatedAt: now.Add(-2 * time.Minute)}}
	return NewStatus(read, statusClock{now: now}, 5*time.Minute), principal, request, read
}

func TestStatusQueryReturnsOnlyScopedAggregateMetadata(t *testing.T) {
	service, principal, request, _ := statusFixture(t)
	status, err := service.Query(context.Background(), principal, request)
	if err != nil || status.State != StatusFresh || status.Queue.Pending != 2 || status.Acknowledgement.Cursor != 8 || status.Recovery.Applied != 3 || status.FreshnessSeconds != 120 {
		t.Fatalf("status=%#v err=%v", status, err)
	}
}

func TestStatusQueryAuthorizationFailureDoesNotCallReadPort(t *testing.T) {
	service, principal, request, read := statusFixture(t)
	principal.Scopes = nil
	if _, err := service.Query(context.Background(), principal, request); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("scope=%v", err)
	}
	principal, _ = NewPrincipal("other-tenant", "device-demo", "subject-demo", []string{ScopeRead})
	if _, err := service.Query(context.Background(), principal, request); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("tenant=%v", err)
	}
	principal, _ = NewPrincipal("tenant-demo", "other-device", "subject-demo", []string{ScopeRead})
	if _, err := service.Query(context.Background(), principal, request); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("device=%v", err)
	}
	if read.queueCalls != 0 || read.acknowledgementCalls != 0 || read.recoveryCalls != 0 {
		t.Fatalf("calls=%d/%d/%d", read.queueCalls, read.acknowledgementCalls, read.recoveryCalls)
	}
}

func TestStatusQueryMakesStaleAndReadFailureStatesExplicit(t *testing.T) {
	service, principal, request, read := statusFixture(t)
	read.recovery.UpdatedAt = time.Date(2026, 8, 14, 23, 50, 0, 0, time.UTC)
	status, err := service.Query(context.Background(), principal, request)
	if err != nil || status.State != StatusStale || status.FreshnessSeconds != 600 {
		t.Fatalf("stale=%#v err=%v", status, err)
	}
	read.err = errors.New("read failure")
	status, err = service.Query(context.Background(), principal, request)
	if !errors.Is(err, ErrStatusUnavailable) || status.State != StatusUnavailable {
		t.Fatalf("failure=%#v err=%v", status, err)
	}
}
