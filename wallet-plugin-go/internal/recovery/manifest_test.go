package recovery

import (
	"crypto/sha256"
	"testing"
)

func TestValidateManifestAcceptsExactBoundManifest(t *testing.T) {
	payload := []byte(`{"events":[]}`)
	digest := sha256.Sum256(payload)
	manifest := Manifest{Version: "recovery-export-v1", TenantID: "tenant-demo", MigrationChecksums: map[string]string{"0001": "abc"}, ProjectionRevision: "projection-v1", PayloadDigest: digest}
	if err := Validate(manifest, "tenant-demo", map[string]string{"0001": "abc"}, "projection-v1", payload); err != nil {
		t.Fatal(err)
	}
}

func TestValidateManifestFailsClosedOnUnknownOrMismatch(t *testing.T) {
	payload := []byte(`{"events":[]}`)
	digest := sha256.Sum256(payload)
	valid := Manifest{Version: "recovery-export-v1", TenantID: "tenant-demo", MigrationChecksums: map[string]string{"0001": "abc"}, ProjectionRevision: "projection-v1", PayloadDigest: digest}
	cases := []struct { name string; manifest Manifest; tenant string; checksums map[string]string; revision string; body []byte }{
		{"unknown version", Manifest{Version: "recovery-export-v2", TenantID: valid.TenantID, MigrationChecksums: valid.MigrationChecksums, ProjectionRevision: valid.ProjectionRevision, PayloadDigest: valid.PayloadDigest}, valid.TenantID, valid.MigrationChecksums, valid.ProjectionRevision, payload},
		{"tenant", valid, "other", valid.MigrationChecksums, valid.ProjectionRevision, payload},
		{"migration", valid, valid.TenantID, map[string]string{"0001": "changed"}, valid.ProjectionRevision, payload},
		{"projection", valid, valid.TenantID, valid.MigrationChecksums, "projection-v2", payload},
		{"payload", valid, valid.TenantID, valid.MigrationChecksums, valid.ProjectionRevision, []byte(`{"events":[1]}`)},
	}
	for _, test := range cases { t.Run(test.name, func(t *testing.T) { if err := Validate(test.manifest, test.tenant, test.checksums, test.revision, test.body); err == nil { t.Fatal("accepted invalid manifest") } }) }
}
