package capability

import (
	"encoding/json"
	"testing"
)

func TestCurrentReportFailsClosedWithoutIdentityAuthority(t *testing.T) {
	report := CurrentReport()
	if report.PublicPaymentSync || report.PublicFlowStatus != "unavailable" || report.IdentityAuthority != "unapproved" || report.InternalCapabilities["identity_authority"] || report.InternalCapabilities["go_sync_transport"] || report.InternalCapabilities["flutter_durable_outbox_tested"] || report.InternalCapabilities["flutter_sync_ack"] {
		t.Fatalf("report=%#v", report)
	}
	encoded, err := json.Marshal(report)
	if err != nil {
		t.Fatal(err)
	}
	if len(encoded) == 0 {
		t.Fatal("empty report")
	}
}

func TestCurrentReportSeparatesImplementedInternalRecoverySeams(t *testing.T) {
	first, second := CurrentReport(), CurrentReport()
	firstJSON, err := json.Marshal(first)
	if err != nil { t.Fatal(err) }
	secondJSON, err := json.Marshal(second)
	if err != nil { t.Fatal(err) }
	if string(firstJSON) != string(secondJSON) { t.Fatalf("non-deterministic report: %s != %s", firstJSON, secondJSON) }
	for _, name := range []string{"go_pairing_internal", "go_pairing_sqlite", "go_immutable_ingest_ack", "recovery_manifest_validation", "recovery_restore_plan", "recovery_restore_journal", "recovery_dry_run", "recovery_coordinator"} {
		if !first.InternalCapabilities[name] { t.Fatalf("missing internal capability %q: %#v", name, first) }
	}
}
