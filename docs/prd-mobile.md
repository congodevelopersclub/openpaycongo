# PRD: Mobile local-first payment inbox and outbox

## Problem Statement

Merchants and payment operators may receive payment evidence while disconnected or on unreliable networks. A user needs to see what was captured, whether it is safe to retry, what has reached the replicated ledger, and what can be recovered after loss. The existing Flutter prototype is not that workflow and must not be represented as one.

## Solution

Build a local-first mobile inbox/outbox that durably records canonical event intent before delivery, proposes parsers without granting them trust, and synchronizes immutable events through the canonical API. The experience gives clear identity, sender-trust, permission, delivery, conflict, and recovery feedback without exposing raw SMS in public sync payloads.

## User Stories

1. As a merchant, I want a payment event recorded locally before a network request, so that a connection outage cannot silently lose it.
2. As a merchant, I want an inbox that distinguishes captured, pending, acknowledged, rejected, and conflicted events, so that I know what action is needed.
3. As a merchant, I want to retry a pending event safely, so that duplicate taps do not create duplicate credits.
4. As a merchant, I want to see the provider, reference, parser version, source, and sender-trust state, so that I can judge payment evidence.
5. As a merchant, I want parsed SMS content kept on my device unless I explicitly approve another handling path, so that private message content is minimized.
6. As a merchant, I want an understandable permission explanation before SMS or biometric prompts, so that consent is informed and refusal has a usable fallback.
7. As a merchant, I want the app to work without SMS permission for manual or merchant-originated events, so that core accounting is not coupled to a sensitive permission.
8. As a merchant, I want the app to preserve the original event identifier, sequence, idempotency key, and digest during retries, so that recovery is deterministic.
9. As a merchant, I want a clear conflict screen when the same key has different evidence, so that I do not overwrite a ledger decision.
10. As a merchant, I want pull progress and acknowledgement state, so that I know whether another device’s changes are reflected locally.
11. As a merchant replacing a lost device, I want to re-enrol and rebuild authorized history from the backend, so that I can resume safely.
12. As a merchant facing both-device-and-server loss, I want an honest recovery explanation, so that I know a provider export or other third authority is required.
13. As a parser reviewer, I want parser changes shown as proposals with samples, sender trust, version, and rollout scope, so that an unsafe parser cannot silently alter accounting.
14. As a privacy-conscious user, I want any Gemma 4 assistance to be optional, consented, redacted, and non-authoritative, so that AI never creates a payment event or sender trust.
15. As an operator, I want a build/version screen and support bundle that excludes secrets and raw SMS by default, so that incidents can be diagnosed responsibly.
16. As a release engineer, I want emulator evidence from a real app journey, so that screenshots prove behavior rather than a mockup.

## Implementation Decisions

- Use durable local inbox/outbox records and immutable canonical events; derive any balance view from events.
- Expose a small sync client interface for push, cursor pull, and cursor acknowledgement; retain keys and digests across retries.
- Separate capture/parsing, sender trust evaluation, event validation, local persistence, synchronization, and presentation into modules with stable public responsibilities.
- Present provider identity, sender trust, parser version, source, delivery state, and failure/recovery guidance in the UI.
- Treat parser changes and optional Gemma 4 suggestions as reviewable proposals only. Validate proposals deterministically and require human approval before rollout.
- Store secrets only in platform-secure facilities once implemented; never claim that the current shared-preference/local-SQLite prototype provides this protection.
- Define device enrolment, revocation, data-retention, and consent policy before enabling production capture.
- Make Payments Inbox the default epicenter. Rows have captured, pending, retrying, acknowledged, rejected, conflicted, and recovery-required states; a sync sheet shows last success, pending count, oldest pending, and stable offline/DNS-TLS, 401, 503/not-ready, contract-mismatch, healthy-pending, and caught-up diagnoses.
- OpenPay must not request SMS access unless target Android API/distribution satisfies default-handler eligibility or an applicable store-policy exception. Ineligible or unsupported installations keep automatic capture off while manual and merchant fallback remain usable. In-context states are not-asked, granted, denied, permanently-denied/settings, and unsupported.
- Normalize `SmsMessage.address`; an exact approved sender set and an active versioned parser are both required before event creation. An untrusted sender can create reviewable evidence but never a credit.
- Capability-discover Gemma 4 before rendering assistance UI. Resource/model/runtime failures always leave manual fallback usable; record model/runtime version and input fingerprint, never send background SMS to a model, and make failure change no parser or ledger state.

## Public Module Interfaces

- Capture accepts permission-gated SMS, manual, and merchant input and returns untrusted evidence.
- Parser evaluation accepts evidence and a versioned approved parser set and returns a proposed canonical event plus trust explanation.
- Inbox/outbox accepts a validated event and exposes ordered delivery state, retry eligibility, and recovery status.
- Sync accepts canonical events and cursors and returns persistence/replay/conflict outcomes and ordered remote pages.
- Identity and permission services expose capability state and reasoned fallback actions without revealing secrets.
- Proposal review accepts parser evidence and returns approved, rejected, or limited-rollout decisions.

## Testing Decisions

- Test observable journeys, not widget internals: offline capture, process restart, retry/replay, conflict, permission refusal, parser proposal review, re-enrolment, and recovery messaging.
- Use deterministic SMS fixtures and a fake canonical server; never use real SMS in test artifacts.
- Add Android emulator integration tests that capture actual app screenshots after an explicit journey; golden images are supplementary, not a substitute for runtime capture.
- Continue narrow parser unit tests, then add public contract and persistence tests before UI detail tests.

## Out of Scope

- Automated account recovery when both device and backend are lost without a third authority.
- Automatic parser approval or autonomous Gemma 4 payment decisions.
- Production signing, app-store publishing, and provider contracts in this planning slice.

## Further Notes

The app must never represent a local parse, a displayed balance, or a queued request as a confirmed payment. The current Flutter project remains an incomplete prototype until these decisions are implemented and released with evidence.

## User Stories (continued)

17. As a merchant, I want Payments Inbox to be the default epicenter, so that pending financial work is visible first.
18. As a merchant, I want rows for captured, pending, retrying, acknowledged, rejected, conflicted, and recovery-required, so that status is unambiguous.
19. As a merchant, I want a sync status sheet with last success, pending count, and oldest pending age, so that I can judge risk.
20. As a merchant, I want distinct offline, DNS/TLS, 401, server-unavailable, and contract-mismatch messages, so that I can take the right action.
21. As a merchant, I want safe retry copy that says what will be reused, so that I do not fear duplicate credit.
22. As a merchant, I want healthy/pending diagnostics without secrets, so that support is actionable.
23. As a merchant, I want normalized sender addresses checked against an allowlist and an active parser, so that unknown senders never credit a wallet.
24. As a merchant, I want an untrusted sender recorded as evidence only, so that I can review without accounting impact.
25. As a merchant, I want a Recovery Required state with next steps, so that loss does not look like success.
26. As support staff, I want a redacted diagnostic bundle, so that no raw SMS or secret leaks.
27. As an auditor, I want replay attempts recorded, so that recovery is accountable.
28. As a user, I want a capability gate before Gemma 4 UI, so that unsupported devices show manual fallback.
29. As a user, I want manual entry to work when model download/runtime fails, so that AI is never required.
30. As a reviewer, I want model/runtime provenance and input fingerprint, so that a proposal is reproducible without raw SMS.
31. As a user, I want no background SMS sent to a model, so that assistance is explicit.
32. As a user, I want model failure to change no parser rule, so that failure is safe.
33. As an operator, I want identity and sender trust visible in each row, so that evidence is explainable.
34. As a merchant, I want wallet membership failures explained without tenant data leakage, so that authorization is understandable.
35. As a tester, I want manual and merchant fallback tested on every SMS-policy state, so that distribution changes do not block accounting.
36. As a release owner, I want actual runtime screenshots only after the journey passes, so that evidence is honest.
