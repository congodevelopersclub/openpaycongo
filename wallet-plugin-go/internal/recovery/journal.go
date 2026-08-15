package recovery

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
)

type JournalState string

const (
	JournalPrepared JournalState = "prepared"
	JournalApplied  JournalState = "applied"
	JournalAborted  JournalState = "aborted"
)

var ErrInvalidJournalTransition = errors.New("invalid restore journal transition")

type MutationPort interface{ ApplyRestore(RestorePlan) error }

type RestoreJournal struct{ entries map[string]JournalState }

func NewRestoreJournal() *RestoreJournal { return &RestoreJournal{entries: map[string]JournalState{}} }

func PlanDigest(plan RestorePlan) string {
	hash := sha256.New()
	hash.Write([]byte(plan.TenantID))
	hash.Write([]byte{0})
	hash.Write([]byte(plan.ProjectionRevision))
	hash.Write([]byte{0})
	hash.Write(plan.PayloadDigest[:])
	return hex.EncodeToString(hash.Sum(nil))
}

func (journal *RestoreJournal) Prepare(plan RestorePlan) (string, error) {
	if journal == nil || plan.TenantID == "" || plan.ProjectionRevision == "" || plan.PayloadDigest == ([sha256.Size]byte{}) {
		return "", ErrInvalidJournalTransition
	}
	digest := PlanDigest(plan)
	if state, exists := journal.entries[digest]; exists && state != JournalPrepared {
		return "", ErrInvalidJournalTransition
	}
	journal.entries[digest] = JournalPrepared
	return digest, nil
}

func (journal *RestoreJournal) Apply(digest string, plan RestorePlan, port MutationPort) error {
	if journal == nil || port == nil || digest != PlanDigest(plan) || journal.entries[digest] != JournalPrepared {
		return ErrInvalidJournalTransition
	}
	if err := port.ApplyRestore(plan); err != nil {
		journal.entries[digest] = JournalAborted
		return err
	}
	journal.entries[digest] = JournalApplied
	return nil
}

func (journal *RestoreJournal) State(digest string) JournalState {
	if journal == nil {
		return ""
	}
	return journal.entries[digest]
}
