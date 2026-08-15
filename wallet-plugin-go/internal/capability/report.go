package capability

import "sort"

type Report struct {
	PublicPaymentSync bool            `json:"public_payment_sync"`
	IdentityAuthority string          `json:"identity_authority"`
	Capabilities      map[string]bool `json:"capabilities"`
	Evidence          []string        `json:"evidence"`
}

// CurrentReport is read-only code-state evidence. It intentionally does not
// probe a network endpoint or accept an endpoint/tenant from untrusted input.
func CurrentReport() Report {
	report := Report{PublicPaymentSync: false, IdentityAuthority: "unapproved", Capabilities: map[string]bool{
		"go_pairing_internal": true, "go_pairing_sqlite": true, "go_sync_transport": false,
		"flutter_sms_capture": true, "flutter_durable_outbox": false, "flutter_sync_ack": false,
		"recovery_internal": true, "identity_authority": false,
	}, Evidence: []string{
		"wallet-plugin-go/internal/pairing/service.go", "wallet-plugin-go/internal/pairing/sqlite_repository.go",
		"wallet-plugin-go/internal/analytics/sqlite/store.go", "android-client/lib/features/sms_gateway",
		"docs/openapi.yaml: identity.example.invalid", "docs/openapi.yaml: /v1/sync endpoints are contract-only",
	}}
	sort.Strings(report.Evidence)
	return report
}
