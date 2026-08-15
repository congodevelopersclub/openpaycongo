package recovery

import (
	"crypto/sha256"
	"errors"
)

const ManifestVersion = "recovery-export-v1"

var ErrInvalidManifest = errors.New("invalid recovery manifest")

// Manifest deliberately carries no keys, raw SMS, or identity credentials.
// Callers supply the already-authenticated tenant and locally known revisions.
type Manifest struct {
	Version            string
	TenantID           string
	MigrationChecksums map[string]string
	ProjectionRevision string
	PayloadDigest      [sha256.Size]byte
}

func Validate(manifest Manifest, tenantID string, checksums map[string]string, projectionRevision string, payload []byte) error {
	if manifest.Version != ManifestVersion || manifest.TenantID == "" || manifest.TenantID != tenantID || manifest.ProjectionRevision == "" || manifest.ProjectionRevision != projectionRevision || len(manifest.MigrationChecksums) == 0 || len(manifest.MigrationChecksums) != len(checksums) { return ErrInvalidManifest }
	for revision, checksum := range checksums { if revision == "" || checksum == "" || manifest.MigrationChecksums[revision] != checksum { return ErrInvalidManifest } }
	if sha256.Sum256(payload) != manifest.PayloadDigest { return ErrInvalidManifest }
	return nil
}
