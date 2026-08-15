package onboarding

// HandoffState is a synthetic, route-free summary for a future merchant setup
// view. It is not authorization to create credentials or activate a tenant.
type HandoffState string

const (
	HandoffIncomplete HandoffState = "incomplete"
	HandoffBlocked    HandoffState = "blocked"
	HandoffReady      HandoffState = "ready_for_human_handoff"
)

// HandoffChecklist deliberately carries only approval and reference presence.
// It never exposes a tenant, store, device, pairing code, or handoff reference.
type HandoffChecklist struct {
	IdentityApproved        bool
	PolicyApproved          bool
	PairingReferencePresent bool
}

type HandoffSummary struct {
	State     HandoffState
	Checklist HandoffChecklist
}

// SummarizeHandoff is deterministic and pure. A ready result means a human may
// perform the next approved handoff; it does not apply setup or activate any
// identity, device, store, or credential.
func SummarizeHandoff(plan Plan, approvals Approval) HandoffSummary {
	checklist := HandoffChecklist{
		IdentityApproved:        approvals.IdentityApproved,
		PolicyApproved:          approvals.PolicyApproved,
		PairingReferencePresent: plan.HandoffReference != "",
	}
	if plan.Status == Incomplete || !checklist.PairingReferencePresent {
		return HandoffSummary{State: HandoffIncomplete, Checklist: checklist}
	}
	if plan.Status != Ready || !checklist.IdentityApproved || !checklist.PolicyApproved {
		return HandoffSummary{State: HandoffBlocked, Checklist: checklist}
	}
	return HandoffSummary{State: HandoffReady, Checklist: checklist}
}
