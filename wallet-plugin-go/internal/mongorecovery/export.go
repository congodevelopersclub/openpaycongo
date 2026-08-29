package mongorecovery

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
)

const ExportVersion = "mongo-recovery-export-v1"

var ErrInvalidExport = errors.New("invalid Mongo recovery export")

// EventDigest is export-safe metadata. It intentionally contains no amount,
// payment reference, raw SMS, credential, enrollment secret, or event body.
type EventDigest struct {
	TenantID string
	Sequence uint64
	Digest   [sha256.Size]byte
}

// ExportManifest binds a tenant-scoped ordered event digest stream to target
// migration and projection identity before any importer opens target writes.
type ExportManifest struct {
	Version            string
	TenantID           string
	EventCount         uint64
	EventsDigest       [sha256.Size]byte
	MigrationChecksums map[string]string
	ProjectionRevision string
	AcknowledgedCursor uint64
}

func AggregateDigest(events []EventDigest) [sha256.Size]byte {
	hash := sha256.New()
	var sequence [8]byte
	for _, event := range events {
		binary.BigEndian.PutUint64(sequence[:], event.Sequence)
		hash.Write(sequence[:])
		hash.Write([]byte(event.TenantID))
		hash.Write([]byte{0})
		hash.Write(event.Digest[:])
	}
	var digest [sha256.Size]byte
	copy(digest[:], hash.Sum(nil))
	return digest
}

// VerifyExport is read-only. Callers must invoke it before target import/write
// admission. Any identity, ordering, digest, or revision mismatch fails closed.
func VerifyExport(manifest ExportManifest, tenantID string, checksums map[string]string, projectionRevision string, events []EventDigest) error {
	if manifest.Version != ExportVersion || manifest.TenantID == "" || manifest.TenantID != tenantID || manifest.ProjectionRevision == "" || manifest.ProjectionRevision != projectionRevision || len(manifest.MigrationChecksums) == 0 || len(manifest.MigrationChecksums) != len(checksums) || manifest.EventCount != uint64(len(events)) || manifest.AcknowledgedCursor > manifest.EventCount || manifest.EventsDigest == ([sha256.Size]byte{}) {
		return ErrInvalidExport
	}
	for revision, checksum := range checksums {
		if revision == "" || checksum == "" || manifest.MigrationChecksums[revision] != checksum {
			return ErrInvalidExport
		}
	}
	for i, event := range events {
		if event.TenantID != tenantID || event.Sequence != uint64(i+1) || event.Digest == ([sha256.Size]byte{}) {
			return ErrInvalidExport
		}
	}
	if AggregateDigest(events) != manifest.EventsDigest {
		return ErrInvalidExport
	}
	return nil
}
