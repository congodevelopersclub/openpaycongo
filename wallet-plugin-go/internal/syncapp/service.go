// Package syncapp contains the internal application boundary for an already
// authenticated sync caller. It deliberately owns neither HTTP nor identity
// token parsing, issuer selection, or public support policy.
package syncapp

import (
	"context"
	"errors"
	"sort"

	"github.com/example/wallet-plugin-go/internal/analytics"
)

const ScopeWrite = "sync:write"

var (
	ErrUnauthorized = errors.New("sync application authorization rejected")
	ErrInactive     = errors.New("sync application pairing inactive")
	ErrInvalidBatch = errors.New("sync application invalid batch")
)

// Principal is supplied by a future identity boundary. This package only
// verifies its already-approved, explicit claims; it never parses a token.
type Principal struct {
	TenantID string
	DeviceID string
	Subject  string
	Scopes   []string
}

func NewPrincipal(tenantID, deviceID, subject string, scopes []string) (Principal, error) {
	if !identifier(tenantID) || !identifier(deviceID) || subject == "" {
		return Principal{}, ErrUnauthorized
	}
	set := make(map[string]struct{}, len(scopes))
	for _, scope := range scopes {
		if scope == "" {
			return Principal{}, ErrUnauthorized
		}
		set[scope] = struct{}{}
	}
	approved := make([]string, 0, len(set))
	for scope := range set {
		approved = append(approved, scope)
	}
	sort.Strings(approved)
	return Principal{TenantID: tenantID, DeviceID: deviceID, Subject: subject, Scopes: approved}, nil
}

func (principal Principal) has(scope string) bool {
	for _, candidate := range principal.Scopes {
		if candidate == scope {
			return true
		}
	}
	return false
}

// Batch is immutable after construction: events are copied before use.
type Batch struct {
	tenantID string
	deviceID string
	events   []analytics.LedgerEvent
	ack      uint64
}

func NewBatch(tenantID, deviceID string, events []analytics.LedgerEvent, acknowledgement uint64) (Batch, error) {
	if !identifier(tenantID) || !identifier(deviceID) || len(events) == 0 || acknowledgement == 0 {
		return Batch{}, ErrInvalidBatch
	}
	copyEvents := append([]analytics.LedgerEvent(nil), events...)
	for _, event := range copyEvents {
		if event.TenantID != tenantID || event.Validate() != nil {
			return Batch{}, ErrInvalidBatch
		}
	}
	return Batch{tenantID: tenantID, deviceID: deviceID, events: copyEvents, ack: acknowledgement}, nil
}

type PairingPort interface {
	IsActive(ctx context.Context, tenantID, deviceID string) (bool, error)
}

type AppendResult struct{ Replayed bool }
type AcknowledgementResult struct{ Replayed bool }

type IngestPort interface {
	Append(ctx context.Context, event analytics.LedgerEvent) (AppendResult, error)
	Acknowledge(ctx context.Context, tenantID, replicaID string, cursor uint64) (AcknowledgementResult, error)
}

type Result struct {
	AcknowledgedCursor      uint64
	EventsReplayed          bool
	AcknowledgementReplayed bool
}

type Service struct {
	pairing PairingPort
	ingest  IngestPort
}

func New(pairing PairingPort, ingest IngestPort) Service {
	if pairing == nil || ingest == nil {
		panic("sync application: nil port")
	}
	return Service{pairing: pairing, ingest: ingest}
}

func (service Service) Apply(ctx context.Context, principal Principal, batch Batch) (Result, error) {
	if ctx.Err() != nil || !authorized(principal, batch) {
		return Result{}, ErrUnauthorized
	}
	active, err := service.pairing.IsActive(ctx, principal.TenantID, principal.DeviceID)
	if err != nil || !active {
		return Result{}, ErrInactive
	}
	replayed := true
	for _, event := range batch.events {
		result, err := service.ingest.Append(ctx, event)
		if err != nil {
			return Result{}, err
		}
		replayed = replayed && result.Replayed
	}
	acknowledgement, err := service.ingest.Acknowledge(ctx, principal.TenantID, principal.DeviceID, batch.ack)
	if err != nil {
		return Result{}, err
	}
	return Result{AcknowledgedCursor: batch.ack, EventsReplayed: replayed, AcknowledgementReplayed: acknowledgement.Replayed}, nil
}

func authorized(principal Principal, batch Batch) bool {
	return principal.has(ScopeWrite) && principal.TenantID == batch.tenantID && principal.DeviceID == batch.deviceID
}

func identifier(value string) bool {
	if len(value) == 0 || len(value) > 128 {
		return false
	}
	for _, c := range value {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.' || c == ':') {
			return false
		}
	}
	return true
}
