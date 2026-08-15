package capability

import (
	"encoding/json"
	"testing"
)

func TestCurrentReportFailsClosedWithoutIdentityAuthority(t *testing.T) {
	report := CurrentReport()
	if report.PublicPaymentSync || report.IdentityAuthority != "unapproved" || report.Capabilities["identity_authority"] || report.Capabilities["go_sync_transport"] || report.Capabilities["flutter_durable_outbox"] {
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
