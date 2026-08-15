package recovery

import (
	"crypto/sha256"
	"testing"
)

func TestDryRunAcceptsMatchingReadOnlySnapshots(t *testing.T) {
	digest := sha256.Sum256([]byte("event-digests"))
	plan := RestorePlan{TenantID: "tenant-demo", ProjectionRevision: "projection-v1", PayloadDigest: sha256.Sum256([]byte("payload"))}
	result := DryRun(plan, Snapshot{EventCount: 2, EventsDigest: digest, ProjectionRevision: "projection-v1"}, Snapshot{EventCount: 2, EventsDigest: digest, ProjectionRevision: "projection-v1"})
	if !result.Ready || len(result.Diagnostics) != 0 {
		t.Fatalf("result=%#v", result)
	}
}

func TestDryRunReturnsOnlyStableMismatchDiagnostics(t *testing.T) {
	plan := RestorePlan{TenantID: "tenant-demo", ProjectionRevision: "projection-v1", PayloadDigest: sha256.Sum256([]byte("payload"))}
	result := DryRun(plan, Snapshot{EventCount: 1, EventsDigest: sha256.Sum256([]byte("source")), ProjectionRevision: "projection-v1"}, Snapshot{EventCount: 2, EventsDigest: sha256.Sum256([]byte("target")), ProjectionRevision: "projection-v2"})
	if result.Ready || len(result.Diagnostics) != 3 || result.Diagnostics[0] != DiagnosticEventCount || result.Diagnostics[1] != DiagnosticEventsDigest || result.Diagnostics[2] != DiagnosticProjectionRevision {
		t.Fatalf("result=%#v", result)
	}
}
