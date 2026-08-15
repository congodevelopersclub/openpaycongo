package recovery

import (
	"crypto/sha256"
	"errors"
	"testing"
)

type recordingMutation struct {
	calls int
	err   error
}

func (mutation *recordingMutation) ApplyRestore(RestorePlan) error {
	mutation.calls++
	return mutation.err
}

func TestRestoreJournalAllowsExactlyOnePreparedApplication(t *testing.T) {
	plan := RestorePlan{TenantID: "tenant-demo", ProjectionRevision: "projection-v1", PayloadDigest: sha256.Sum256([]byte("payload"))}
	journal := NewRestoreJournal()
	digest, err := journal.Prepare(plan)
	if err != nil {
		t.Fatal(err)
	}
	mutation := &recordingMutation{}
	if err := journal.Apply(digest, plan, mutation); err != nil {
		t.Fatal(err)
	}
	if journal.State(digest) != JournalApplied || mutation.calls != 1 {
		t.Fatalf("state=%q calls=%d", journal.State(digest), mutation.calls)
	}
	if err := journal.Apply(digest, plan, mutation); !errors.Is(err, ErrInvalidJournalTransition) {
		t.Fatalf("reordered apply: %v", err)
	}
}

func TestRestoreJournalAbortsOnMutationFailure(t *testing.T) {
	plan := RestorePlan{TenantID: "tenant-demo", ProjectionRevision: "projection-v1", PayloadDigest: sha256.Sum256([]byte("payload"))}
	journal := NewRestoreJournal()
	digest, err := journal.Prepare(plan)
	if err != nil {
		t.Fatal(err)
	}
	failure := errors.New("fail")
	if err := journal.Apply(digest, plan, &recordingMutation{err: failure}); !errors.Is(err, failure) {
		t.Fatalf("apply=%v", err)
	}
	if journal.State(digest) != JournalAborted {
		t.Fatalf("state=%q", journal.State(digest))
	}
}
