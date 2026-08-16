package mongorecovery

import (
	"context"
	"crypto/sha256"
	"errors"
	"os"
	"testing"

	"github.com/example/wallet-plugin-go/internal/recovery"
	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
)

func recoveryPlan() recovery.RestorePlan {
	return recovery.RestorePlan{TenantID: "tenant-a", ProjectionRevision: "projection-v1", PayloadDigest: sha256.Sum256([]byte("canonical-event-digest"))}
}

func TestJournalRejectsInvalidInputsWithoutDatabase(t *testing.T) {
	if _, err := (*Journal)(nil).Prepare(context.Background(), recoveryPlan()); !errors.Is(err, ErrTransition) {
		t.Fatalf("prepare err=%v", err)
	}
	if err := (*Journal)(nil).Transition(context.Background(), "tenant-a", "digest", recovery.JournalApplied); !errors.Is(err, ErrTransition) {
		t.Fatalf("transition err=%v", err)
	}
}

func TestMongoRecoveryJournalRuntime(t *testing.T) {
	uri := os.Getenv("MONGO_RECOVERY_URI")
	if uri == "" {
		t.Skip("MONGO_RECOVERY_URI not configured")
	}
	ctx := context.Background()
	client, err := mongo.Connect(options.Client().ApplyURI(uri))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Disconnect(ctx)
	entries := client.Database("recovery").Collection("journal")
	reuse := os.Getenv("MONGO_RECOVERY_REUSE") != ""
	if !reuse {
		if err := entries.Drop(ctx); err != nil {
			t.Fatal(err)
		}
	}
	journal := New(entries)
	if err := journal.EnsureIndexes(ctx); err != nil {
		t.Fatal(err)
	}
	plan := recoveryPlan()
	if reuse {
		state, err := journal.State(ctx, plan.TenantID, recovery.PlanDigest(plan))
		if err != nil || state != recovery.JournalApplied {
			t.Fatalf("restart state=%q err=%v", state, err)
		}
		if _, err := journal.Prepare(ctx, plan); !errors.Is(err, ErrTransition) {
			t.Fatalf("restart replay=%v", err)
		}
		coordinatorPlan := recovery.RestorePlan{TenantID: plan.TenantID, ProjectionRevision: plan.ProjectionRevision, PayloadDigest: sha256.Sum256([]byte("coordinator-runtime-events"))}
		snapshot := applicationSnapshot(coordinatorPlan)
		mutation := &mutationFake{}
		replay, err := (Application{Journal: journal, Mutation: mutation}).Execute(ctx, coordinatorPlan, snapshot, snapshot)
		if err != nil || !replay.Replayed || mutation.credits != 0 {
			t.Fatalf("restart application replay=%+v credits=%d err=%v", replay, mutation.credits, err)
		}
		return
	}
	digest, err := journal.Prepare(ctx, plan)
	if err != nil {
		t.Fatal(err)
	}
	if replay, err := journal.Prepare(ctx, plan); err != nil || replay != digest {
		t.Fatalf("replay=%q err=%v", replay, err)
	}
	if err := journal.Transition(ctx, plan.TenantID, digest, recovery.JournalApplied); err != nil {
		t.Fatal(err)
	}
	if state, err := journal.State(ctx, plan.TenantID, digest); err != nil || state != recovery.JournalApplied {
		t.Fatalf("state=%q err=%v", state, err)
	}
	if _, err := journal.Prepare(ctx, plan); !errors.Is(err, ErrTransition) {
		t.Fatalf("terminal replay=%v", err)
	}
	if err := journal.Transition(ctx, plan.TenantID, digest, recovery.JournalAborted); !errors.Is(err, ErrTransition) {
		t.Fatalf("retransition=%v", err)
	}
	if _, err := journal.State(ctx, "tenant-b", digest); err == nil {
		t.Fatal("cross-tenant state lookup succeeded")
	}
	var indexes []bson.M
	cursor, err := entries.Indexes().List(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := cursor.All(ctx, &indexes); err != nil {
		t.Fatal(err)
	}
	if len(indexes) < 2 {
		t.Fatalf("indexes=%d", len(indexes))
	}
	coordinatorPlan := recovery.RestorePlan{TenantID: plan.TenantID, ProjectionRevision: plan.ProjectionRevision, PayloadDigest: sha256.Sum256([]byte("coordinator-runtime-events"))}
	snapshot := applicationSnapshot(coordinatorPlan)
	mutation := &mutationFake{}
	application := Application{Journal: journal, Mutation: mutation}
	result, err := application.Execute(ctx, coordinatorPlan, snapshot, snapshot)
	if err != nil || result.Replayed || mutation.credits != 1 {
		t.Fatalf("application result=%+v credits=%d err=%v", result, mutation.credits, err)
	}
	replay, err := application.Execute(ctx, coordinatorPlan, snapshot, snapshot)
	if err != nil || !replay.Replayed || replay.OperationID != result.OperationID || mutation.credits != 1 {
		t.Fatalf("application replay=%+v credits=%d err=%v", replay, mutation.credits, err)
	}
}
