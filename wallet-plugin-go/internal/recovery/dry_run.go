package recovery

import "crypto/sha256"

type Snapshot struct {
	EventCount         uint32
	EventsDigest       [sha256.Size]byte
	ProjectionRevision string
}

type Diagnostic string

const (
	DiagnosticEventCount         Diagnostic = "event_count_mismatch"
	DiagnosticEventsDigest       Diagnostic = "events_digest_mismatch"
	DiagnosticProjectionRevision Diagnostic = "projection_revision_mismatch"
)

type DryRunResult struct {
	Diagnostics []Diagnostic
	Ready       bool
}

// DryRun compares already-read snapshots only. It does not retain raw events,
// credentials, or payment data and has no mutation capability.
func DryRun(plan RestorePlan, source, target Snapshot) DryRunResult {
	result := DryRunResult{Diagnostics: make([]Diagnostic, 0, 3)}
	if source.EventCount != target.EventCount {
		result.Diagnostics = append(result.Diagnostics, DiagnosticEventCount)
	}
	if source.EventsDigest != target.EventsDigest {
		result.Diagnostics = append(result.Diagnostics, DiagnosticEventsDigest)
	}
	if source.ProjectionRevision != target.ProjectionRevision || source.ProjectionRevision != plan.ProjectionRevision {
		result.Diagnostics = append(result.Diagnostics, DiagnosticProjectionRevision)
	}
	result.Ready = len(result.Diagnostics) == 0
	return result
}
