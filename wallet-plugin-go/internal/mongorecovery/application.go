package mongorecovery

import (
	"context"
	"errors"

	"github.com/example/wallet-plugin-go/internal/recovery"
)

var ErrDryRun = errors.New("recovery dry-run mismatch")

// ApplyOncePort is the only mutation authority the recovery application needs.
// Implementations must bind operationID to the same datastore transaction as
// any credit-affecting change: a retry of an already committed operationID must
// return success without creating another credit.
type ApplyOncePort interface {
	ApplyOnce(context.Context, recovery.RestorePlan, string) error
}

type durableJournal interface {
	Prepare(context.Context, recovery.RestorePlan) (string, error)
	Transition(context.Context, string, string, recovery.JournalState) error
	State(context.Context, string, string) (recovery.JournalState, error)
}

// AbortError makes an executor's terminal refusal explicit. Transient errors
// deliberately leave the durable plan prepared so the same operation ID can be
// resumed safely after a process or primary failure.
type AbortError struct{ Err error }

func (e AbortError) Error() string { return e.Err.Error() }
func (e AbortError) Unwrap() error { return e.Err }

type Result struct {
	OperationID string
	Replayed    bool
}

// Application validates a read-only dry run before recording a durable plan.
// The stable plan digest is the mutation idempotency key, so a crash between
// the mutation and JournalApplied transition resumes without duplicate credit.
type Application struct {
	Journal  durableJournal
	Mutation ApplyOncePort
}

func (a Application) Execute(ctx context.Context, plan recovery.RestorePlan, source, target recovery.Snapshot) (Result, error) {
	if a.Journal == nil || a.Mutation == nil {
		return Result{}, ErrTransition
	}
	if result := recovery.DryRun(plan, source, target); !result.Ready {
		return Result{}, ErrDryRun
	}
	digest, err := a.Journal.Prepare(ctx, plan)
	if err != nil {
		state, stateErr := a.Journal.State(ctx, plan.TenantID, recovery.PlanDigest(plan))
		if stateErr == nil && state == recovery.JournalApplied {
			return Result{OperationID: recovery.PlanDigest(plan), Replayed: true}, nil
		}
		return Result{}, err
	}
	if err := a.Mutation.ApplyOnce(ctx, plan, digest); err != nil {
		var abort AbortError
		if errors.As(err, &abort) {
			if transitionErr := a.Journal.Transition(ctx, plan.TenantID, digest, recovery.JournalAborted); transitionErr != nil {
				return Result{}, transitionErr
			}
		}
		return Result{}, err
	}
	if err := a.Journal.Transition(ctx, plan.TenantID, digest, recovery.JournalApplied); err != nil {
		return Result{}, err
	}
	return Result{OperationID: digest}, nil
}
