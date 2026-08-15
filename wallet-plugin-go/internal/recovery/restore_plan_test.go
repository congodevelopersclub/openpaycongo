package recovery

import (
	"crypto/sha256"
	"testing"
)

func TestStageRestorePlanIsDeterministicAfterFullValidation(t *testing.T) {
	payload := []byte(`{"events":[]}`)
	manifest := Manifest{Version: ManifestVersion, TenantID: "tenant-demo", MigrationChecksums: map[string]string{"0001": "abc"}, ProjectionRevision: "projection-v1", PayloadDigest: sha256.Sum256(payload)}
	first, err := StageRestore(manifest, "tenant-demo", map[string]string{"0001": "abc"}, "projection-v1", payload)
	if err != nil { t.Fatal(err) }
	second, err := StageRestore(manifest, "tenant-demo", map[string]string{"0001": "abc"}, "projection-v1", payload)
	if err != nil || first != second { t.Fatalf("plans: %#v %#v %v", first, second, err) }
}

func TestStageRestorePlanDoesNotExistForInvalidManifest(t *testing.T) {
	payload := []byte(`{"events":[]}`)
	manifest := Manifest{Version: ManifestVersion, TenantID: "tenant-demo", MigrationChecksums: map[string]string{"0001": "abc"}, ProjectionRevision: "projection-v1", PayloadDigest: sha256.Sum256(payload)}
	if _, err := StageRestore(manifest, "tenant-demo", map[string]string{"0001": "different"}, "projection-v1", payload); err == nil { t.Fatal("staged invalid restore") }
}
