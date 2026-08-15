package mongopayment

import (
	"errors"
	"testing"
)

func TestReplayResultRequiresExactTenantDeviceKeyAndCanonicalBytes(t *testing.T) {
	p := Payment{TenantID: "tenant-a", DeviceID: "device-a", IdempotencyKey: "key-a", Canonical: "canonical-payment"}
	if got, err := ReplayResult(p, p); err != nil || got.Canonical != p.Canonical {
		t.Fatalf("exact replay: %#v %v", got, err)
	}
	for _, changed := range []Payment{{TenantID: "tenant-b", DeviceID: p.DeviceID, IdempotencyKey: p.IdempotencyKey, Canonical: p.Canonical}, {TenantID: p.TenantID, DeviceID: "device-b", IdempotencyKey: p.IdempotencyKey, Canonical: p.Canonical}, {TenantID: p.TenantID, DeviceID: p.DeviceID, IdempotencyKey: p.IdempotencyKey, Canonical: "conflict"}} {
		if _, err := ReplayResult(p, changed); !errors.Is(err, ErrConflict) {
			t.Fatalf("expected conflict: %v", err)
		}
	}
}
