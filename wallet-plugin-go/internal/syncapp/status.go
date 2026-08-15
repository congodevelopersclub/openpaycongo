package syncapp

import (
	"context"
	"errors"
	"time"
)

const ScopeRead = "sync:read"

var ErrStatusUnavailable = errors.New("sync status unavailable")

type StatusState string

const (
	StatusFresh       StatusState = "fresh"
	StatusStale       StatusState = "stale"
	StatusUnavailable StatusState = "unavailable"
)

// StatusRequest is scoped to the already authenticated principal. It contains
// no payment identifiers or payload material.
type StatusRequest struct{ tenantID, deviceID string }

func NewStatusRequest(tenantID, deviceID string) (StatusRequest, error) {
	if !identifier(tenantID) || !identifier(deviceID) {
		return StatusRequest{}, ErrUnauthorized
	}
	return StatusRequest{tenantID: tenantID, deviceID: deviceID}, nil
}

type QueueCounters struct {
	Pending  uint64
	InFlight uint64
	Failed   uint64
}

type AcknowledgementMetadata struct {
	Cursor        uint64
	AcceptedCount uint64
}

type RecoveryCounters struct {
	Prepared  uint64
	Applied   uint64
	Aborted   uint64
	UpdatedAt time.Time
}

// StatusReadPort is read-only by design. It exposes aggregate metadata only,
// never individual payment events or their payloads.
type StatusReadPort interface {
	ReadQueue(ctx context.Context, tenantID, deviceID string) (QueueCounters, error)
	ReadAcknowledgement(ctx context.Context, tenantID, deviceID string) (AcknowledgementMetadata, error)
	ReadRecovery(ctx context.Context, tenantID, deviceID string) (RecoveryCounters, error)
}

type StatusClock interface{ Now() time.Time }

type SyncStatus struct {
	State            StatusState
	Queue            QueueCounters
	Acknowledgement  AcknowledgementMetadata
	Recovery         RecoveryCounters
	FreshnessSeconds uint64
}

type StatusService struct {
	read       StatusReadPort
	clock      StatusClock
	staleAfter time.Duration
}

func NewStatus(read StatusReadPort, clock StatusClock, staleAfter time.Duration) StatusService {
	if read == nil || clock == nil || staleAfter <= 0 {
		panic("sync status: invalid port or freshness bound")
	}
	return StatusService{read: read, clock: clock, staleAfter: staleAfter}
}

func (service StatusService) Query(ctx context.Context, principal Principal, request StatusRequest) (SyncStatus, error) {
	if ctx.Err() != nil || !principal.has(ScopeRead) || principal.TenantID != request.tenantID || principal.DeviceID != request.deviceID {
		return SyncStatus{}, ErrUnauthorized
	}
	queue, err := service.read.ReadQueue(ctx, request.tenantID, request.deviceID)
	if err != nil {
		return SyncStatus{State: StatusUnavailable}, ErrStatusUnavailable
	}
	acknowledgement, err := service.read.ReadAcknowledgement(ctx, request.tenantID, request.deviceID)
	if err != nil {
		return SyncStatus{State: StatusUnavailable}, ErrStatusUnavailable
	}
	recovery, err := service.read.ReadRecovery(ctx, request.tenantID, request.deviceID)
	if err != nil || recovery.UpdatedAt.IsZero() {
		return SyncStatus{State: StatusUnavailable}, ErrStatusUnavailable
	}
	now := service.clock.Now().UTC()
	age := now.Sub(recovery.UpdatedAt.UTC())
	if age < 0 {
		age = 0
	}
	result := SyncStatus{Queue: queue, Acknowledgement: acknowledgement, Recovery: recovery, FreshnessSeconds: uint64(age / time.Second), State: StatusFresh}
	if age > service.staleAfter {
		result.State = StatusStale
	}
	return result, nil
}
