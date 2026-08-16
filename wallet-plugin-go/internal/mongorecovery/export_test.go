package mongorecovery

import (
	"crypto/sha256"
	"errors"
	"testing"
)

func exportFixture() (ExportManifest, []EventDigest) {
	events := []EventDigest{
		{TenantID: "tenant-a", Sequence: 1, Digest: sha256.Sum256([]byte("event-1"))},
		{TenantID: "tenant-a", Sequence: 2, Digest: sha256.Sum256([]byte("event-2"))},
	}
	manifest := ExportManifest{Version: ExportVersion, TenantID: "tenant-a", EventCount: 2, EventsDigest: AggregateDigest(events), MigrationChecksums: map[string]string{"0001": "checksum-a"}, ProjectionRevision: "projection-v1", AcknowledgedCursor: 2}
	return manifest, events
}

func TestVerifyExportAcceptsBoundMetadataOnly(t *testing.T) {
	manifest, events := exportFixture()
	if err := VerifyExport(manifest, "tenant-a", map[string]string{"0001": "checksum-a"}, "projection-v1", events); err != nil {
		t.Fatal(err)
	}
}

func TestVerifyExportFailsClosedBeforeAnyImportWrite(t *testing.T) {
	manifest, events := exportFixture()
	cases := []struct {
		name      string
		manifest  ExportManifest
		events    []EventDigest
		tenant    string
		checksums map[string]string
		revision  string
	}{
		{"unknown version", ExportManifest{Version: "mongo-recovery-export-v2", TenantID: manifest.TenantID, EventCount: manifest.EventCount, EventsDigest: manifest.EventsDigest, MigrationChecksums: manifest.MigrationChecksums, ProjectionRevision: manifest.ProjectionRevision}, events, "tenant-a", map[string]string{"0001": "checksum-a"}, "projection-v1"},
		{"tenant", manifest, events, "tenant-b", map[string]string{"0001": "checksum-a"}, "projection-v1"},
		{"count", ExportManifest{Version: manifest.Version, TenantID: manifest.TenantID, EventCount: 3, EventsDigest: manifest.EventsDigest, MigrationChecksums: manifest.MigrationChecksums, ProjectionRevision: manifest.ProjectionRevision}, events, "tenant-a", map[string]string{"0001": "checksum-a"}, "projection-v1"},
		{"checksum", manifest, events, "tenant-a", map[string]string{"0001": "wrong"}, "projection-v1"},
		{"digest", ExportManifest{Version: manifest.Version, TenantID: manifest.TenantID, EventCount: manifest.EventCount, EventsDigest: sha256.Sum256([]byte("wrong")), MigrationChecksums: manifest.MigrationChecksums, ProjectionRevision: manifest.ProjectionRevision}, events, "tenant-a", map[string]string{"0001": "checksum-a"}, "projection-v1"},
		{"gap", manifest, []EventDigest{events[0], {TenantID: "tenant-a", Sequence: 3, Digest: events[1].Digest}}, "tenant-a", map[string]string{"0001": "checksum-a"}, "projection-v1"},
		{"cross tenant", manifest, []EventDigest{events[0], {TenantID: "tenant-b", Sequence: 2, Digest: events[1].Digest}}, "tenant-a", map[string]string{"0001": "checksum-a"}, "projection-v1"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if err := VerifyExport(tc.manifest, tc.tenant, tc.checksums, tc.revision, tc.events); !errors.Is(err, ErrInvalidExport) {
				t.Fatalf("err=%v", err)
			}
		})
	}
}

func TestEventDigestCarriesNoPaymentPayload(t *testing.T) {
	typ := EventDigest{}
	if typ.TenantID != "" || typ.Sequence != 0 || typ.Digest != ([sha256.Size]byte{}) {
		t.Fatal("unexpected public export fields")
	}
}
