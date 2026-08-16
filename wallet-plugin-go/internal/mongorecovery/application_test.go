package mongorecovery

import (
	"context"
	"crypto/sha256"
	"errors"
	"testing"
	"time"

	"github.com/example/wallet-plugin-go/internal/recovery"
)

type journalFake struct {
	digest string
	state  recovery.JournalState
	err    error
}

func (f *journalFake) Prepare(_ context.Context, plan recovery.RestorePlan) (string, error) {
	if f.err != nil {
		return "", f.err
	}
	if f.digest == "" {
		f.digest = recovery.PlanDigest(plan)
	}
	if f.state == recovery.JournalApplied || f.state == recovery.JournalAborted {
		return "", ErrTransition
	}
	f.state = recovery.JournalPrepared
	return f.digest, nil
}
func (f *journalFake) Transition(_ context.Context, _ string, _ string, state recovery.JournalState) error {
	f.state = state
	return nil
}
func (f *journalFake) State(_ context.Context, _ string, _ string) (recovery.JournalState, error) {
	if f.state == "" {
		return "", errors.New("not found")
	}
	return f.state, nil
}

type mutationFake struct {
	calls, credits int
	operationID    string
	err            error
	applied        map[string]bool
}

func (f *mutationFake) ApplyOnce(_ context.Context, _ recovery.RestorePlan, operationID string) error {
	f.calls++
	f.operationID = operationID
	if f.err != nil {
		return f.err
	}
	if f.applied == nil {
		f.applied = map[string]bool{}
	}
	if !f.applied[operationID] {
		f.applied[operationID] = true
		f.credits++
	}
	return nil
}

func applicationPlan() recovery.RestorePlan {
	return recovery.RestorePlan{TenantID: "tenant-a", ProjectionRevision: "projection-v1", PayloadDigest: sha256.Sum256([]byte("canonical-events"))}
}
func applicationSnapshot(plan recovery.RestorePlan) recovery.Snapshot {
	return recovery.Snapshot{EventCount: 2, EventsDigest: sha256.Sum256([]byte("events")), ProjectionRevision: plan.ProjectionRevision}
}

func TestApplicationIsReadOnlyUntilDryRunAndUsesStableOperationID(t *testing.T) {
	plan := applicationPlan()
	snapshot := applicationSnapshot(plan)
	journal := &journalFake{}
	mutation := &mutationFake{}
	app := Application{Journal: journal, Mutation: mutation}
	bad := snapshot
	bad.EventCount++
	if _, err := app.Execute(context.Background(), plan, snapshot, bad); !errors.Is(err, ErrDryRun) {
		t.Fatalf("dry run=%v", err)
	}
	if mutation.calls != 0 {
		t.Fatalf("mutated before dry run: %d", mutation.calls)
	}
	result, err := app.Execute(context.Background(), plan, snapshot, snapshot)
	if err != nil {
		t.Fatal(err)
	}
	if mutation.calls != 1 || mutation.credits != 1 || result.Replayed || mutation.operationID != recovery.PlanDigest(plan) || journal.state != recovery.JournalApplied {
		t.Fatalf("calls=%d credits=%d result=%+v operation=%q state=%q", mutation.calls, mutation.credits, result, mutation.operationID, journal.state)
	}
	replay, err := app.Execute(context.Background(), plan, snapshot, snapshot)
	if err != nil || !replay.Replayed || replay.OperationID != result.OperationID || mutation.credits != 1 {
		t.Fatalf("replay=%+v err=%v credits=%d", replay, err, mutation.credits)
	}
}

func TestApplicationLeavesTransientFailurePreparedAndAbortsExplicitRefusal(t *testing.T) {
	plan := applicationPlan()
	snapshot := applicationSnapshot(plan)
	journal := &journalFake{}
	failure := errors.New("target rejected")
	mutation := &mutationFake{err: failure}
	app := Application{Journal: journal, Mutation: mutation}
	if _, err := app.Execute(context.Background(), plan, snapshot, snapshot); !errors.Is(err, failure) {
		t.Fatalf("execute=%v", err)
	}
	if mutation.calls != 1 || journal.state == recovery.JournalAborted {
		t.Fatalf("transient calls=%d state=%q", mutation.calls, journal.state)
	}
	mutation.err = AbortError{Err: failure}
	if _, err := app.Execute(context.Background(), plan, snapshot, snapshot); !errors.Is(err, failure) {
		t.Fatalf("abort=%v", err)
	}
	if journal.state != recovery.JournalAborted {
		t.Fatalf("state=%q", journal.state)
	}
}

type blockingMutation struct{ called int }

func (f *blockingMutation) ApplyOnce(ctx context.Context, _ recovery.RestorePlan, _ string) error {
	f.called++
	<-ctx.Done()
	return ctx.Err()
}

func TestApplicationBoundsExecutorAndLeavesTimeoutResumable(t *testing.T) {
	plan := applicationPlan()
	snapshot := applicationSnapshot(plan)
	journal := &journalFake{}
	mutation := &blockingMutation{}
	_, err := (Application{Journal: journal, Mutation: mutation, Timeout: time.Millisecond}).Execute(context.Background(), plan, snapshot, snapshot)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("timeout=%v", err)
	}
	if mutation.called != 1 || journal.state != recovery.JournalPrepared {
		t.Fatalf("calls=%d state=%q", mutation.called, journal.state)
	}
}
