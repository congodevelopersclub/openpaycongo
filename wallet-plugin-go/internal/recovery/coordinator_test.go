package recovery

import (
	"crypto/sha256"
	"errors"
	"testing"
)

func coordinatorFixture() (Manifest, []byte, Snapshot, RestorePlan) {
	payload := []byte(`{"events":[]}`)
	plan := RestorePlan{TenantID: "tenant-demo", ProjectionRevision: "projection-v1", PayloadDigest: sha256.Sum256(payload)}
	manifest := Manifest{Version: ManifestVersion, TenantID: plan.TenantID, MigrationChecksums: map[string]string{"0001": "abc"}, ProjectionRevision: plan.ProjectionRevision, PayloadDigest: plan.PayloadDigest}
	snapshot := Snapshot{EventCount: 1, EventsDigest: sha256.Sum256([]byte("events")), ProjectionRevision: plan.ProjectionRevision}
	return manifest, payload, snapshot, plan
}

func TestCoordinatorNeverMutatesBeforeValidationAndDryRun(t *testing.T) {
	manifest, payload, snapshot, _ := coordinatorFixture()
	mutation := &recordingMutation{}
	coordinator := Coordinator{Journal: NewRestoreJournal(), Mutation: mutation}
	if err := coordinator.Execute(manifest, "wrong", map[string]string{"0001": "abc"}, "projection-v1", payload, snapshot, snapshot); err == nil || mutation.calls != 0 {
		t.Fatalf("validation err=%v calls=%d", err, mutation.calls)
	}
	bad := snapshot
	bad.EventCount++
	if err := coordinator.Execute(manifest, "tenant-demo", map[string]string{"0001": "abc"}, "projection-v1", payload, snapshot, bad); !errors.Is(err, ErrDryRunMismatch) || mutation.calls != 0 {
		t.Fatalf("dry run err=%v calls=%d", err, mutation.calls)
	}
}

func TestCoordinatorJournalsSuccessFailureAndRejectsReplay(t *testing.T) {
	manifest, payload, snapshot, plan := coordinatorFixture()
	journal := NewRestoreJournal()
	mutation := &recordingMutation{}
	coordinator := Coordinator{Journal: journal, Mutation: mutation}
	if err := coordinator.Execute(manifest, "tenant-demo", map[string]string{"0001": "abc"}, "projection-v1", payload, snapshot, snapshot); err != nil {
		t.Fatal(err)
	}
	digest := PlanDigest(plan)
	if journal.State(digest) != JournalApplied || mutation.calls != 1 {
		t.Fatalf("state=%q calls=%d", journal.State(digest), mutation.calls)
	}
	if err := coordinator.Execute(manifest, "tenant-demo", map[string]string{"0001": "abc"}, "projection-v1", payload, snapshot, snapshot); !errors.Is(err, ErrInvalidJournalTransition) {
		t.Fatalf("replay=%v", err)
	}
	failing := &recordingMutation{err: errors.New("fail")}
	second := Coordinator{Journal: NewRestoreJournal(), Mutation: failing}
	if err := second.Execute(manifest, "tenant-demo", map[string]string{"0001": "abc"}, "projection-v1", payload, snapshot, snapshot); err == nil {
		t.Fatal("mutation failure accepted")
	}
	if second.Journal.State(digest) != JournalAborted {
		t.Fatalf("state=%q", second.Journal.State(digest))
	}
}
