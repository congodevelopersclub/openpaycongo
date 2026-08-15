// Package onboarding is an internal, route-free merchant setup workflow.
package onboarding

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"sort"
)

const ScopeAdmin = "merchant:admin"

var (
	ErrUnauthorized = errors.New("merchant onboarding authorization rejected")
	ErrRejected     = errors.New("merchant onboarding command rejected")
	ErrUnavailable  = errors.New("merchant onboarding unavailable")
)

type Principal struct {
	TenantID, Subject string
	Scopes            []string
}

func NewPrincipal(t, s string, scopes []string) (Principal, error) {
	if t == "" || s == "" {
		return Principal{}, ErrUnauthorized
	}
	return Principal{t, s, append([]string(nil), scopes...)}, nil
}
func (p Principal) allowed() bool {
	for _, s := range p.Scopes {
		if s == ScopeAdmin {
			return true
		}
	}
	return false
}

type Approval struct{ IdentityApproved, PolicyApproved bool }
type Status string

const (
	Incomplete Status = "incomplete"
	Blocked    Status = "blocked"
	Ready      Status = "ready"
)

type Plan struct {
	TenantID, StoreID, DeviceID, HandoffReference, Digest string
	Status                                                Status
}
type Planner interface {
	PairingHandoffReference(context.Context, string, string, string) (string, error)
}
type IdempotencyReader interface {
	FindOnboarding(context.Context, string) (string, bool, error)
}
type Writer interface {
	ApplySetup(context.Context, Plan, Audit) error
}
type Audit struct{ TenantID, Subject, IdempotencyKey, PlanDigest, Outcome string }
type Service struct {
	planner Planner
	keys    IdempotencyReader
	writer  Writer
}

func New(planner Planner, keys IdempotencyReader, writer Writer) Service {
	if planner == nil || keys == nil || writer == nil {
		panic("onboarding: nil port")
	}
	return Service{planner, keys, writer}
}
func (s Service) Prepare(ctx context.Context, p Principal, tenant, store, device string, a Approval) (Plan, error) {
	if ctx.Err() != nil || !p.allowed() || p.TenantID != tenant || tenant == "" || store == "" || device == "" {
		return Plan{}, ErrUnauthorized
	}
	ref, e := s.planner.PairingHandoffReference(ctx, tenant, store, device)
	if e != nil || ref == "" {
		return Plan{}, ErrUnavailable
	}
	status := Ready
	if !a.IdentityApproved || !a.PolicyApproved {
		status = Blocked
	}
	h := sha256.Sum256([]byte(tenant + "\x00" + store + "\x00" + device + "\x00" + ref + "\x00" + string(status)))
	return Plan{tenant, store, device, ref, hex.EncodeToString(h[:]), status}, nil
}
func (s Service) Apply(ctx context.Context, p Principal, plan Plan, digest, key string) (Status, error) {
	if ctx.Err() != nil || !p.allowed() || p.TenantID != plan.TenantID || plan.Status != Ready || digest != plan.Digest || key == "" {
		return Incomplete, ErrRejected
	}
	existing, found, e := s.keys.FindOnboarding(ctx, key)
	if e != nil {
		return Incomplete, ErrUnavailable
	}
	if found {
		if existing == plan.Digest {
			return Ready, nil
		}
		return Incomplete, ErrRejected
	}
	if e = s.writer.ApplySetup(ctx, plan, Audit{plan.TenantID, p.Subject, key, plan.Digest, "applied"}); e != nil {
		return Incomplete, ErrUnavailable
	}
	return Ready, nil
}
func StablePlanDigest(values ...string) string {
	sort.Strings(values)
	h := sha256.Sum256([]byte(join(values)))
	return hex.EncodeToString(h[:])
}
func join(values []string) string {
	r := ""
	for _, v := range values {
		r += lenPrefix(v)
	}
	return r
}
func lenPrefix(v string) string { return string(rune(len(v))) + v }
