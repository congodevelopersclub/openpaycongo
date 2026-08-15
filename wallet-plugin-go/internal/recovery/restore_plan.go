package recovery

import "crypto/sha256"

// RestorePlan is a validated immutable description only. Applying a plan is a
// separate, explicitly authorized datastore concern.
type RestorePlan struct {
	TenantID           string
	ProjectionRevision string
	PayloadDigest      [sha256.Size]byte
}

func StageRestore(manifest Manifest, tenantID string, checksums map[string]string, projectionRevision string, payload []byte) (RestorePlan, error) {
	if err := Validate(manifest, tenantID, checksums, projectionRevision, payload); err != nil { return RestorePlan{}, err }
	return RestorePlan{TenantID: manifest.TenantID, ProjectionRevision: manifest.ProjectionRevision, PayloadDigest: manifest.PayloadDigest}, nil
}
