package operatorread

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strconv"
)

const ScopeReconcile = "operator:reconcile"

var ErrCommandRejected = errors.New("operator reconciliation command rejected")

type ReconciliationPlan struct {
	TenantID, Revision, Digest string
	CandidateCount             uint64
}
type PlanSource interface {
	PrepareReconciliation(context.Context, string) (revision string, candidateCount uint64, snapshotDigest [sha256.Size]byte, err error)
}
type IdempotencyReader interface {
	FindReconciliation(context.Context, string) (planDigest string, found bool, err error)
}

// MutationPort is an explicitly injected command boundary. It must not alter
// immutable payment events; it applies reconciliation metadata and appends the
// supplied non-sensitive audit record atomically.
type MutationPort interface {
	ApplyReconciliation(context.Context, ReconciliationPlan, AuditRecord) error
}
type AuditRecord struct{ TenantID, Subject, IdempotencyKey, PlanDigest, Outcome string }
type CommandResult struct{ Code string }
type ReconciliationService struct {
	plans       PlanSource
	idempotency IdempotencyReader
	mutation    MutationPort
}

func NewReconciliation(plans PlanSource, idempotency IdempotencyReader, mutation MutationPort) ReconciliationService {
	if plans == nil || idempotency == nil || mutation == nil {
		panic("operator reconciliation: nil port")
	}
	return ReconciliationService{plans, idempotency, mutation}
}
func (s ReconciliationService) Prepare(ctx context.Context, p Principal, tenant string) (ReconciliationPlan, error) {
	if ctx.Err() != nil || !p.has(ScopeReconcile) || p.TenantID != tenant {
		return ReconciliationPlan{}, ErrUnauthorized
	}
	revision, count, snapshot, err := s.plans.PrepareReconciliation(ctx, tenant)
	if err != nil || revision == "" {
		return ReconciliationPlan{}, ErrUnavailable
	}
	digest := sha256.Sum256([]byte(tenant + "\x00" + revision + "\x00" + strconv.FormatUint(count, 10) + "\x00" + hex.EncodeToString(snapshot[:])))
	return ReconciliationPlan{TenantID: tenant, Revision: revision, CandidateCount: count, Digest: hex.EncodeToString(digest[:])}, nil
}
func (s ReconciliationService) Apply(ctx context.Context, p Principal, plan ReconciliationPlan, suppliedDigest, idempotencyKey string) (CommandResult, error) {
	if ctx.Err() != nil || !p.has(ScopeReconcile) || p.TenantID != plan.TenantID || plan.Digest == "" || suppliedDigest != plan.Digest || idempotencyKey == "" {
		return CommandResult{Code: "rejected"}, ErrCommandRejected
	}
	existing, found, err := s.idempotency.FindReconciliation(ctx, idempotencyKey)
	if err != nil {
		return CommandResult{Code: "unavailable"}, ErrUnavailable
	}
	if found {
		if existing == plan.Digest {
			return CommandResult{Code: "replayed"}, nil
		}
		return CommandResult{Code: "rejected"}, ErrCommandRejected
	}
	audit := AuditRecord{TenantID: plan.TenantID, Subject: p.Subject, IdempotencyKey: idempotencyKey, PlanDigest: plan.Digest, Outcome: "applied"}
	if err := s.mutation.ApplyReconciliation(ctx, plan, audit); err != nil {
		return CommandResult{Code: "unavailable"}, ErrUnavailable
	}
	return CommandResult{Code: "applied"}, nil
}
func (p Principal) has(scope string) bool {
	for _, s := range p.Scopes {
		if s == scope {
			return true
		}
	}
	return false
}
