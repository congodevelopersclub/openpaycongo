package operatorread

import (
	"context"
	"errors"
	"testing"
	"time"
)

type c struct{ now time.Time }

func (x c) Now() time.Time { return x.now }

type f struct {
	calls  int
	err    error
	totals Totals
	ack    AckMetadata
	rec    ReconciliationMetadata
}

func (x *f) Totals(context.Context, string, Window) (Totals, error) {
	x.calls++
	return x.totals, x.err
}
func (x *f) Acknowledgement(context.Context, string) (AckMetadata, error) {
	x.calls++
	return x.ack, x.err
}
func (x *f) Reconciliation(context.Context, string, Window) (ReconciliationMetadata, error) {
	x.calls++
	return x.rec, x.err
}
func fixture(t *testing.T) (Service, Principal, Window, *f) {
	now := time.Date(2026, 8, 15, 0, 0, 0, 0, time.UTC)
	last := now.Add(-time.Minute)
	x := &f{totals: Totals{"10", "0", "10", "1", "0"}, ack: AckMetadata{10, 10, &last}, rec: ReconciliationMetadata{"0", nil}}
	p, e := NewPrincipal("tenant", "operator", []string{ScopeRead})
	if e != nil {
		t.Fatal(e)
	}
	w := Window{now.Add(-time.Hour), now}
	return New(x, x, x, c{now}), p, w, x
}
func TestOperatorReadHealthyAndAggregateOnly(t *testing.T) {
	s, p, w, _ := fixture(t)
	got, e := s.Query(context.Background(), p, "tenant", w)
	if e != nil || got.State != Healthy || got.AckLag != "0" || got.FreshnessSeconds != "60" {
		t.Fatalf("%#v %v", got, e)
	}
}
func TestOperatorReadAuthFailureCallsNoPorts(t *testing.T) {
	s, p, w, x := fixture(t)
	p.Scopes = nil
	if _, e := s.Query(context.Background(), p, "tenant", w); !errors.Is(e, ErrUnauthorized) {
		t.Fatal(e)
	}
	if x.calls != 0 {
		t.Fatal(x.calls)
	}
	p.Scopes = []string{ScopeRead}
	if _, e := s.Query(context.Background(), p, "other", w); !errors.Is(e, ErrUnauthorized) || x.calls != 0 {
		t.Fatal(e, x.calls)
	}
}
func TestOperatorReadDistinguishesStaleReconcilingUnavailable(t *testing.T) {
	s, p, w, x := fixture(t)
	old := w.To.Add(-16 * time.Minute)
	x.ack.LastReceivedAt = &old
	got, e := s.Query(context.Background(), p, "tenant", w)
	if e != nil || got.State != Stale {
		t.Fatal(got, e)
	}
	x.ack.LastReceivedAt = &w.To
	x.rec.UnreconciledCount = "1"
	got, e = s.Query(context.Background(), p, "tenant", w)
	if e != nil || got.State != Reconciling {
		t.Fatal(got, e)
	}
	x.err = errors.New("down")
	got, e = s.Query(context.Background(), p, "tenant", w)
	if !errors.Is(e, ErrUnavailable) || got.State != Unavailable {
		t.Fatal(got, e)
	}
}
