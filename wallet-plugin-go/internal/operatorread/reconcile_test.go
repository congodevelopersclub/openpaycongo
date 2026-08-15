package operatorread

import (
	"context"
	"crypto/sha256"
	"errors"
	"testing"
)

type planFake struct{ calls int }

func (f *planFake) PrepareReconciliation(context.Context, string) (string, uint64, [32]byte, error) {
	f.calls++
	return "r1", 2, sha256.Sum256([]byte("snapshot")), nil
}

type keyFake struct {
	calls  int
	found  bool
	digest string
}

func (f *keyFake) FindReconciliation(context.Context, string) (string, bool, error) {
	f.calls++
	return f.digest, f.found, nil
}

type mutationFake struct {
	calls int
	audit AuditRecord
}

func (f *mutationFake) ApplyReconciliation(_ context.Context, _ ReconciliationPlan, a AuditRecord) error {
	f.calls++
	f.audit = a
	return nil
}
func commandFixture(t *testing.T) (ReconciliationService, Principal, *planFake, *keyFake, *mutationFake) {
	p, e := NewPrincipal("tenant", "operator", []string{ScopeReconcile})
	if e != nil {
		t.Fatal(e)
	}
	a, b, c := &planFake{}, &keyFake{}, &mutationFake{}
	return NewReconciliation(a, b, c), p, a, b, c
}
func TestReconciliationCommandPlansAppliesAndAudits(t *testing.T) {
	s, p, _, _, m := commandFixture(t)
	plan, e := s.Prepare(context.Background(), p, "tenant")
	if e != nil || plan.Digest == "" {
		t.Fatal(plan, e)
	}
	got, e := s.Apply(context.Background(), p, plan, plan.Digest, "key-1")
	if e != nil || got.Code != "applied" || m.calls != 1 || m.audit.Outcome != "applied" {
		t.Fatal(got, e, m)
	}
}
func TestReconciliationCommandRejectsBeforeMutation(t *testing.T) {
	s, p, plans, keys, m := commandFixture(t)
	p.Scopes = nil
	if _, e := s.Prepare(context.Background(), p, "tenant"); !errors.Is(e, ErrUnauthorized) || plans.calls != 0 {
		t.Fatal(e, plans.calls)
	}
	p.Scopes = []string{ScopeReconcile}
	plan, e := s.Prepare(context.Background(), p, "tenant")
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.Apply(context.Background(), p, plan, "stale", "key"); !errors.Is(e, ErrCommandRejected) || m.calls != 0 {
		t.Fatal(e, m.calls)
	}
	keys.found = true
	keys.digest = "other"
	if _, e = s.Apply(context.Background(), p, plan, plan.Digest, "key"); !errors.Is(e, ErrCommandRejected) || m.calls != 0 {
		t.Fatal(e, m.calls)
	}
	p.TenantID = "other"
	if _, e = s.Apply(context.Background(), p, plan, plan.Digest, "key"); !errors.Is(e, ErrCommandRejected) || m.calls != 0 {
		t.Fatal(e, m.calls)
	}
}
func TestReconciliationCommandExactKeyReplayDoesNotMutate(t *testing.T) {
	s, p, _, keys, m := commandFixture(t)
	plan, e := s.Prepare(context.Background(), p, "tenant")
	if e != nil {
		t.Fatal(e)
	}
	keys.found = true
	keys.digest = plan.Digest
	got, e := s.Apply(context.Background(), p, plan, plan.Digest, "key")
	if e != nil || got.Code != "replayed" || m.calls != 0 {
		t.Fatal(got, e, m.calls)
	}
}
