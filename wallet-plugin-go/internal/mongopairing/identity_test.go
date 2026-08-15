package mongopairing

import (
	"errors"
	"testing"
)

func TestValidateRequiresCanonicalScope(t *testing.T) {
	valid := Identity{TenantID: "tenant-a", InstallID: "install-a", DeviceID: "device-a", IntentID: "intent-a", Status: "pending_confirmation"}
	if err := Validate(valid); err != nil {
		t.Fatalf("valid identity: %v", err)
	}
	for _, changed := range []Identity{{InstallID: valid.InstallID, DeviceID: valid.DeviceID, IntentID: valid.IntentID, Status: valid.Status}, {TenantID: valid.TenantID, DeviceID: valid.DeviceID, IntentID: valid.IntentID, Status: valid.Status}, {TenantID: valid.TenantID, InstallID: valid.InstallID, IntentID: valid.IntentID, Status: valid.Status}, {TenantID: valid.TenantID, InstallID: valid.InstallID, DeviceID: valid.DeviceID, Status: valid.Status}, {TenantID: valid.TenantID, InstallID: valid.InstallID, DeviceID: valid.DeviceID, IntentID: valid.IntentID}} {
		if !errors.Is(Validate(changed), ErrInvalid) {
			t.Fatalf("incomplete identity was accepted: %#v", changed)
		}
	}
}
