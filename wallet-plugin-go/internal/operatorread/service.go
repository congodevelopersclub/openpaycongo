// Package operatorread is a route-free, aggregate-only operator application boundary.
package operatorread

import (
	"context"
	"errors"
	"strconv"
	"time"

	"github.com/example/wallet-plugin-go/internal/analytics"
)

const ScopeRead = "operator:read"

var (
	ErrUnauthorized = errors.New("operator read authorization rejected")
	ErrUnavailable  = errors.New("operator read unavailable")
)

type Principal struct {
	TenantID, Subject string
	Scopes            []string
}

func NewPrincipal(tenant, subject string, scopes []string) (Principal, error) {
	if tenant == "" || subject == "" {
		return Principal{}, ErrUnauthorized
	}
	return Principal{TenantID: tenant, Subject: subject, Scopes: append([]string(nil), scopes...)}, nil
}
func (p Principal) allows() bool {
	for _, s := range p.Scopes {
		if s == ScopeRead {
			return true
		}
	}
	return false
}

type Window struct{ From, To time.Time }

func (w Window) valid() bool {
	return w.From.Location() == time.UTC && w.To.Location() == time.UTC && w.From.Before(w.To)
}

type Totals struct{ GrossMinor, RefundsMinor, NetMinor, PaymentCount, RefundCount string }
type AckMetadata struct {
	AcceptedCursor, AcknowledgedCursor uint64
	LastReceivedAt                     *time.Time
}
type ReconciliationMetadata struct {
	UnreconciledCount    string
	OldestUnreconciledAt *time.Time
}
type TotalsPort interface {
	Totals(context.Context, string, Window) (Totals, error)
}
type AckPort interface {
	Acknowledgement(context.Context, string) (AckMetadata, error)
}
type ReconciliationPort interface {
	Reconciliation(context.Context, string, Window) (ReconciliationMetadata, error)
}
type Clock interface{ Now() time.Time }
type State string

const (
	Healthy     State = "healthy"
	Stale       State = "stale"
	Reconciling State = "reconciling"
	Unavailable State = "unavailable"
)

type Reason string

const (
	ReasonAckLag                Reason = "ack_lagging"
	ReasonSyncStale             Reason = "sync_stale"
	ReasonReconciliationPending Reason = "reconciliation_pending"
	ReasonReconciliationOverdue Reason = "reconciliation_overdue"
)

type Status struct {
	State            State
	Totals           Totals
	Window           Window
	AckLag           string
	FreshnessSeconds string
	Reasons          []Reason
}
type Service struct {
	totals         TotalsPort
	ack            AckPort
	reconciliation ReconciliationPort
	clock          Clock
}

func New(t TotalsPort, a AckPort, r ReconciliationPort, c Clock) Service {
	if t == nil || a == nil || r == nil || c == nil {
		panic("operator read: nil port")
	}
	return Service{t, a, r, c}
}
func (s Service) Query(ctx context.Context, p Principal, tenant string, w Window) (Status, error) {
	if ctx.Err() != nil || !p.allows() || p.TenantID != tenant || !w.valid() {
		return Status{}, ErrUnauthorized
	}
	totals, err := s.totals.Totals(ctx, tenant, w)
	if err != nil || !validTotals(totals) {
		return Status{State: Unavailable}, ErrUnavailable
	}
	ack, err := s.ack.Acknowledgement(ctx, tenant)
	if err != nil || ack.AcknowledgedCursor > ack.AcceptedCursor {
		return Status{State: Unavailable}, ErrUnavailable
	}
	reconciliation, err := s.reconciliation.Reconciliation(ctx, tenant, w)
	if err != nil || !decimal(reconciliation.UnreconciledCount) {
		return Status{State: Unavailable}, ErrUnavailable
	}
	status := Status{State: Healthy, Totals: totals, Window: w, AckLag: strconv.FormatUint(ack.AcceptedCursor-ack.AcknowledgedCursor, 10), Reasons: []Reason{}}
	if status.AckLag != "0" {
		status.Reasons = append(status.Reasons, ReasonAckLag)
	}
	now := s.clock.Now().UTC()
	if ack.LastReceivedAt != nil {
		age := now.Sub(ack.LastReceivedAt.UTC())
		if age < 0 {
			age = 0
		}
		status.FreshnessSeconds = strconv.FormatInt(int64(age/time.Second), 10)
		if age > analytics.SyncStaleAfter {
			status.State = Stale
			status.Reasons = append(status.Reasons, ReasonSyncStale)
		}
	}
	if reconciliation.UnreconciledCount != "0" {
		status.Reasons = append(status.Reasons, ReasonReconciliationPending)
		if reconciliation.OldestUnreconciledAt != nil && now.Sub(reconciliation.OldestUnreconciledAt.UTC()) > analytics.ReconciliationOverdueAfter {
			status.Reasons = append(status.Reasons, ReasonReconciliationOverdue)
		}
		if status.State == Healthy {
			status.State = Reconciling
		}
	}
	return status, nil
}
func decimal(v string) bool {
	if v == "" || (len(v) > 1 && v[0] == '0') {
		return false
	}
	for _, c := range v {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}
func validTotals(t Totals) bool {
	return decimal(t.GrossMinor) && decimal(t.RefundsMinor) && decimal(t.NetMinor) && decimal(t.PaymentCount) && decimal(t.RefundCount)
}
