package onboarding

import "testing"

func TestSummarizeHandoffIsRedactedAndDeterministic(t *testing.T) {
	plan := Plan{
		TenantID:         "tenant-sensitive",
		StoreID:          "store-sensitive",
		DeviceID:         "device-sensitive",
		HandoffReference: "reference-not-for-display",
		Digest:           "digest-not-for-display",
		Status:           Ready,
	}
	approvals := Approval{IdentityApproved: true, PolicyApproved: true}
	first, second := SummarizeHandoff(plan, approvals), SummarizeHandoff(plan, approvals)
	if first != second || first.State != HandoffReady || !first.Checklist.PairingReferencePresent {
		t.Fatalf("unexpected handoff summary: %#v %#v", first, second)
	}
}

func TestSummarizeHandoffRequiresCompletePlanAndExplicitApprovals(t *testing.T) {
	for _, test := range []struct {
		name      string
		plan      Plan
		approvals Approval
		want      HandoffState
	}{
		{"missing reference", Plan{Status: Ready}, Approval{true, true}, HandoffIncomplete},
		{"incomplete plan", Plan{HandoffReference: "reference", Status: Incomplete}, Approval{true, true}, HandoffIncomplete},
		{"plan blocked", Plan{HandoffReference: "reference", Status: Blocked}, Approval{true, true}, HandoffBlocked},
		{"identity unapproved", Plan{HandoffReference: "reference", Status: Ready}, Approval{PolicyApproved: true}, HandoffBlocked},
		{"policy unapproved", Plan{HandoffReference: "reference", Status: Ready}, Approval{IdentityApproved: true}, HandoffBlocked},
		{"ready only for human handoff", Plan{HandoffReference: "reference", Status: Ready}, Approval{true, true}, HandoffReady},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := SummarizeHandoff(test.plan, test.approvals); got.State != test.want {
				t.Fatalf("state = %q, want %q", got.State, test.want)
			}
		})
	}
}
