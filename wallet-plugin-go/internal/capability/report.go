package capability

import "sort"

type Report struct {
	PublicPaymentSync      bool            `json:"public_payment_sync"`
	PublicFlowStatus       string          `json:"public_flow_status"`
	IdentityAuthority      string          `json:"identity_authority"`
	InternalCapabilities   map[string]bool `json:"internal_capabilities"`
	Evidence               []string        `json:"evidence"`
}

// CurrentReport is read-only code-state evidence. It intentionally does not
// probe a network endpoint or accept an endpoint/tenant from untrusted input.
func CurrentReport() Report {
	report := Report{PublicPaymentSync: false, PublicFlowStatus: "unavailable", IdentityAuthority: "unapproved", InternalCapabilities: map[string]bool{
		"go_pairing_internal":             true,
		"go_pairing_sqlite":               true,
		"go_immutable_ingest_ack":         true,
		"recovery_manifest_validation":    true,
		"recovery_restore_plan":           true,
		"recovery_restore_journal":        true,
		"recovery_dry_run":                true,
		"recovery_coordinator":            true,
		"go_sync_transport":               false,
		"flutter_sms_capture":             true,
		"flutter_durable_outbox_tested":   false,
		"flutter_sync_ack":                false,
		"identity_authority":              false,
	}, Evidence: []string{
		"wallet-plugin-go/internal/pairing/service.go", "wallet-plugin-go/internal/pairing/sqlite_repository.go", "wallet-plugin-go/internal/analytics/sqlite/store.go",
		"wallet-plugin-go/internal/recovery/manifest.go", "wallet-plugin-go/internal/recovery/restore_plan.go", "wallet-plugin-go/internal/recovery/journal.go", "wallet-plugin-go/internal/recovery/dry_run.go", "wallet-plugin-go/internal/recovery/coordinator.go",
		"android-client/lib/features/sms_gateway",
		"docs/openapi.yaml: identity.example.invalid", "docs/openapi.yaml: /v1/sync endpoints are contract-only",
	}}
	sort.Strings(report.Evidence)
	return report
}
