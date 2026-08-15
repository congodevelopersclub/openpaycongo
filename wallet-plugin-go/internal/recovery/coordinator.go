package recovery

import "errors"

var ErrDryRunMismatch = errors.New("recovery dry-run mismatch")

type Coordinator struct {
	Journal  *RestoreJournal
	Mutation MutationPort
}

func (coordinator Coordinator) Execute(manifest Manifest, tenantID string, checksums map[string]string, projectionRevision string, payload []byte, source, target Snapshot) error {
	if coordinator.Journal == nil || coordinator.Mutation == nil {
		return ErrInvalidJournalTransition
	}
	plan, err := StageRestore(manifest, tenantID, checksums, projectionRevision, payload)
	if err != nil {
		return err
	}
	if result := DryRun(plan, source, target); !result.Ready {
		return ErrDryRunMismatch
	}
	digest, err := coordinator.Journal.Prepare(plan)
	if err != nil {
		return err
	}
	return coordinator.Journal.Apply(digest, plan, coordinator.Mutation)
}
