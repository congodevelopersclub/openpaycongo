package onboarding

import (
	"context"
	"errors"
	"testing"
)

type plannerFake struct{ calls int }

func (f *plannerFake) PairingHandoffReference(context.Context, string, string, string) (string, error) {
	f.calls++
	return "handoff-ref-1", nil
}

type keyFake struct {
	calls  int
	found  bool
	digest string
}

func (f *keyFake) FindOnboarding(context.Context, string) (string, bool, error) {
	f.calls++
	return f.digest, f.found, nil
}

type writerFake struct {
	calls int
	audit Audit
}

func (f *writerFake) ApplySetup(_ context.Context, _ Plan, a Audit) error {
	f.calls++
	f.audit = a
	return nil
}
func fixture(t *testing.T) (Service, Principal, *plannerFake, *keyFake, *writerFake) {
	p, e := NewPrincipal("tenant", "merchant", []string{ScopeAdmin})
	if e != nil {
		t.Fatal(e)
	}
	a, b, c := &plannerFake{}, &keyFake{}, &writerFake{}
	return New(a, b, c), p, a, b, c
}
func TestOnboardingNeedsApprovalsThenAppliesAuditedSetup(t *testing.T) {
	s, p, _, _, w := fixture(t)
	blocked, e := s.Prepare(context.Background(), p, "tenant", "store", "device", Approval{})
	if e != nil || blocked.Status != Blocked {
		t.Fatal(blocked, e)
	}
	if _, e = s.Apply(context.Background(), p, blocked, blocked.Digest, "k"); !errors.Is(e, ErrRejected) || w.calls != 0 {
		t.Fatal(e, w.calls)
	}
	plan, e := s.Prepare(context.Background(), p, "tenant", "store", "device", Approval{true, true})
	if e != nil {
		t.Fatal(e)
	}
	got, e := s.Apply(context.Background(), p, plan, plan.Digest, "k")
	if e != nil || got != Ready || w.calls != 1 || w.audit.Outcome != "applied" {
		t.Fatal(got, e, w)
	}
}
func TestOnboardingRejectsBeforeWrites(t *testing.T) {
	s, p, planner, keys, w := fixture(t)
	p.Scopes = nil
	if _, e := s.Prepare(context.Background(), p, "tenant", "store", "device", Approval{true, true}); !errors.Is(e, ErrUnauthorized) || planner.calls != 0 {
		t.Fatal(e, planner.calls)
	}
	p.Scopes = []string{ScopeAdmin}
	plan, e := s.Prepare(context.Background(), p, "tenant", "store", "device", Approval{true, true})
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.Apply(context.Background(), p, plan, "stale", "k"); !errors.Is(e, ErrRejected) || w.calls != 0 {
		t.Fatal(e, w.calls)
	}
	keys.found = true
	keys.digest = "other"
	if _, e = s.Apply(context.Background(), p, plan, plan.Digest, "k"); !errors.Is(e, ErrRejected) || w.calls != 0 {
		t.Fatal(e, w.calls)
	}
	p.TenantID = "other"
	if _, e = s.Apply(context.Background(), p, plan, plan.Digest, "k"); !errors.Is(e, ErrRejected) || w.calls != 0 {
		t.Fatal(e, w.calls)
	}
}
