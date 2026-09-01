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
6. As a merchant, I want an understandable disclosure before SMS or biometric prompts, so that consent is informed and data use is explicit.
7. As a merchant, I understand automatic financial-SMS capture is the critical core feature and product content remains blocked when `RECEIVE_SMS` is refused.
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
- OpenPay requests only `RECEIVE_SMS`, in context, for its critical SMS-based financial-transaction and money-management feature. It does not request `READ_SMS`, sending, MMS/WAP, Call Log, notification-listener, or default-SMS role. Google Play exception approval and the Permissions Declaration Form remain release gates; repository code is not approval evidence. Product content stays blocked in denied, permanently-denied/settings, and unavailable states.
- Normalize `SmsMessage.address`; an exact approved sender set and an active versioned parser are both required before event creation. The native receiver discards an untrusted sender before body parsing or persistence; it can never create evidence or a credit.
- Capability-discover Gemma 4 before rendering assistance UI. Resource/model/runtime failures always leave manual fallback usable; record model/runtime version and input fingerprint, never send background SMS to a model, and make failure change no parser or ledger state.

## Public Module Interfaces

- Capture accepts permission-gated OS SMS. Manual templates and samples configure or review parsing only; they cannot bypass the permission gate or enter the product ledger as captured payment evidence.
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

## SMS capture, review and Gemma 4

**Payment Inbox** is the visual epicenter. It contains no seeded payment data and no manual-evidence bypass. Manual templates configure parsing only. Captured rows come from the native encrypted inbox, remain evidence rather than confirmed payments, and leave the row only after the native decision journal durably commits a reviewed, rejected, or processed outcome. Review copy states that the raw encrypted SMS will be removed after commit; rejection requires a separate explicit confirmation describing that deletion. Trusted-rule UI always reloads the encrypted native list and offers explicit revoke/clear operations. The decision journal is local evidence, not a canonical ledger event or backend acknowledgement.

Android declares only `RECEIVE_SMS` and a manifest `SMS_RECEIVED` receiver. A prominent in-app disclosure appears before the system prompt and explains the core purpose, local encrypted trusted-sender inbox, and prohibited raw-SMS destinations. The top-level gate constructs no product UI before grant. Denial has retry/settings guidance but no product bypass. The app does not claim default-SMS status. Google Play lists SMS-based financial transactions and SMS-based money management as exception candidates, subject to review and approval; release must not proceed without an accepted declaration.

Trusted sender invariant: normalize only OS sender metadata into exact E.164 (`+`, a `1-9` country-code digit, then 7-14 digits) or 3-11 upper-case ASCII alphanumeric ID. Refuse wildcard matching, arbitrary regex, Unicode lookalikes and message-body sender claims. The receiver checks the encrypted exact allowlist before reading or persisting the body. It bounds a delivered envelope to 4 KiB, eight segments, 31 days and five minutes of clock skew and uses a deterministic digest for idempotency.

Native storage uses separate Android Keystore aliases and separately tagged ciphertext inventories for rules versus inbox/decision data, unique AES-GCM nonces, and domain-separated version/type/identity AAD. Existing ciphertext invalidates only its own missing domain key; first creation of the other domain key remains valid. Untagged quarantine ciphertext fails closed for explicit recovery. Before every journal ciphertext quarantine, including decision tombstones, native storage atomically writes and directory-syncs a domain-specific `journal-recovery-required` marker. Status, export, pending recovery, and decision mutation check that marker first after restart; there is no in-app clear. A missing manifest means an empty journal only when the marker and all pending, index, tombstone, and tagged-quarantine journal inventory are absent. Any final recovery-required state caused by journal, rules, or raw-inbox corruption or key loss publishes null decision count and byte fields. The no-backup queue uses one encrypted file per record, a unique digest filename, at most 500 rows and 2 MiB of encrypted inbox data. Creation and atomic writes sync their parent directories through injectable Android `Os.fsync`; JVM ordering tests are not proof of power-loss behavior on every device/filesystem. Compact encrypted per-digest decision tombstones are append-only in this slice: there is no local delete, age/count/byte cap, or automatic pruning. An encrypted manifest and 64-record encrypted index segments provide bounded status and cursor export; each page returns at most 100 records plus explicit `next_cursor`/`truncated` truth and re-authenticates only those tombstones. Authenticated server acknowledgement before pruning is future work.

A bounded two-thread dispatcher uses a bounded work queue, rejection policy and four-second monotonic queue deadline. A 4.5-second watchdog cancels queued/running work cooperatively and finishes each `PendingResult` exactly once. It never runs capture I/O on `onReceive`. On capture-dispatch rejection, the pending broadcast stays open until the bounded reporter attempts a capture-miss signal. If the watchdog scheduler itself is saturated, the receiver finishes immediately before making a best-effort overload report; it cannot wait for that reporter and has no watchdog fallback. The signal is minimal plaintext metadata (`overload`/`expired` plus local timestamp), contains no sender/body/digest, and may still be erased by process death or unavailable storage. This is detectable best effort, not a zero-loss guarantee.

An overload/expiry capture-miss signal is a warning and never blocks later capture or reading existing evidence. Only inbox capacity or actual storage, corruption, or key-invalidation faults block new capture. A bounded sentinel probe may clear only a transient storage fault. Corrupt or key-inaccessible ciphertext is quarantined; the app never silently regenerates a key over existing ciphertext. Recovery copy directs the user to Android Clear storage or reinstall and explicitly warns that this permanently discards unrecoverable local data. No receiver path logs or invokes Gemma.

Every trusted-rule list/add/revoke/clear, health read, inbox drain, probe, cursor export, and review decision runs off the Android main thread on one bounded serialized bridge worker with a deadline scheduled before enqueue and cooperative cancellation. It checks `RECEIVE_SMS`, foreground state and the unlock generation before work and rechecks before delivering the result. Executor saturation returns an explicit busy error. A deadline returns `outcome_unknown`: an uninterruptible native mutation may already have committed, so the UI attempts an authoritative rules/inbox reload instead of blindly retrying. Successful reconciliation is shown as authoritative; failed or timed-out reconciliation remains an explicit unknown state and never claims the reload succeeded. All mutations are idempotent. Activity destruction completes pending calls once as denied. Pause/hidden/detached lifecycle states immediately hide product content and set the native bridge locked; resume requires a fresh real biometric/PIN result before drain. Permission resume checks use generation ordering so an older asynchronous grant or storage result cannot reveal product content after revocation.

Gemma 4 remains capability-gated with no constructible `ready` UI state in this slice. Model-package verification and inference are ports only; native LiteRT-LM integration is pending. A future adapter must verify local model digest/signature before exposing an action. Proposal input/output and time are bounded; strict JSON fields, provider, amount, currency, reference, confidence and replay are deterministically checked. Every valid proposal still requires human review and can never establish sender trust, activate a parser, create a payment event or credit a ledger. Missing model, inadequate device, timeout, circuit-open, malformed output or runtime failure leaves manual review usable and changes no accounting/parser state. No background SMS upload.

## Native implementation status and follow-up

The minimal receiver, runtime-permission bridge, exact trusted-sender vault, generation-checked permission/foreground/unlock drain gate, durable local decision-before-delete flow, critical-fault UI and lifecycle relock are implemented. JVM tests cover AAD tampering, ciphertext corruption/quarantine, key invalidation inventory, idempotency, capacity, every decision transaction phase/restart, append-only replay beyond 1,000 decisions, strict segmented cursor progress, transient storage probing, bounded overload/expiry including blocked reporters, and stale unlock generations through injectable boundaries. Storage schema/AAD/key aliases are explicitly v3. Detecting any ciphertext under the unreleased v2 development root fails closed as `legacy_migration_required` and leaves it untouched; recovery currently requires Android Clear storage or reinstall with explicit local-loss copy. `docs/github-issue-native-sms-keystore.md` records release evidence still required: real-device process-death/Keystore tests, low-storage behavior, server-acknowledged decision pruning/export, Play exception approval, and audited Gemma runtime. The exported debug APK is test evidence only, not production-ready.

## Google Play declaration evidence plan

- Core feature: receive provider financial-transaction SMS and turn exact trusted evidence into reviewable payment candidates. Without `RECEIVE_SMS`, OpenPay Congo is intentionally unusable; the store listing and demo must show this before any secondary capability.
- Minimal access: `RECEIVE_SMS` only. No history import, sending, MMS, WAP, default-handler role, notification access, or unrelated-message processing.
- Demo: cold launch; read disclosure; tap **Allow SMS capture**; grant Android permission; authenticate; store an exact sender rule; close the process; deliver one trusted and one untrusted test SMS; reopen and authenticate again; show only the trusted encrypted record; choose **Mark reviewed**; show removal only after the durable local decision commits; then show capacity/fault messaging with a test fixture.
- Data boundary: untrusted bodies are not persisted; trusted raw bodies stay encrypted on device until a durable local review decision commits; raw SMS never enters logs, telemetry, support bundles, backend sync, or Gemma. The local decision is not backend delivery or confirmed payment. Only a separately validated canonical payment event may sync later.
- Release evidence: accepted Play Permissions Declaration, privacy policy, Data safety answers, disclosure screenshots/video, and reviewer credentials. Approval is external state, not inferred from tests.

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
35. As a tester, I want every SMS-policy state tested at the top-level gate, so that refusal never exposes payment content or an undeclared fallback.
36. As a release owner, I want actual runtime screenshots only after the journey passes, so that evidence is honest.

## Normative device pairing contract

This section is normative for Android/Flutter pairing work. The wire protocol is [ADR 004](adr-004-secure-device-enrollment.md), `pairing-v2.fixture.json`, and `pairing-v2-test-plan.md`. Do not represent mobile pairing as end-to-end available until QR validation, secure pending storage, completion/replay, SAS confirmation, activation, and active-envelope tests are proven.

- Accept only the exact canonical completion endpoint grammar: lowercase ASCII DNS with at least two labels,
  optional canonical decimal port 1-65535, and exact path `/v1/pairing/complete`. Reject IP literals,
  userinfo, queries, fragments, percent-encoding, alternate paths, trailing slash, and non-UTC-second expiry.
- Verify every bounded signed QR field, including `pairing_secret`, `trust_mode`, exact enrollment Ed25519 public key, and
  `SHA-256(public_key) == fingerprint`, before key agreement. `pinned_continuity` additionally requires an
  existing matching trusted pin. `first_use_requires_sas` is provisional: physical QR plus the independently
  compared mandatory SAS is the bootstrap only when local pin state is absent and the user grants explicit
  authenticated local recovery authorization. Both modes must inspect local pin state; an existing pin can
  never silently downgrade to first use. The device cannot activate before the administrator confirms SAS.
- Generate fresh X25519 client keypair. Use maintained Sodium binding `crypto_kx_client_session_keys`; never
  raw scalar multiplication or custom KDF. Generate unique random 24-byte XChaCha20-Poly1305 nonce. Client-send
  encrypts exactly QR 32-byte secret with completion AAD. Client-receive decrypts result with response AAD.
- Keep pending directional keys, QR, exact retry bytes, nonce, ciphertext, and SAS in Keystore-backed secure
  storage. They cannot sign, sync, or authorize application calls before activation. Exact retry returns same
  encrypted `201`; never re-encrypt changed plaintext under saved key/nonce. Crash without durable retry state
  deletes pending material and requires new QR.
- Laravel confirmation, activation delivery, and `POST /mobile/envelopes` v1 exist. Android #211 adds native
  local deposit-envelope sealing only: foreground/unlock-gated, bounded payload, native send-key use,
  Keystore-encrypted no-backup counter, canonical AAD, and opaque routing-safe result. HTTP delivery, encrypted
  response handling, acknowledgement, revocation, rotation, and recovery remain follow-up work. After activation,
  active bodies use directional XChaCha20-Poly1305 envelopes with locked monotonic counter and canonical AAD; TLS
  terminator sees no cleartext business/PII body.
- Initial pairing still derives directional-key copies in Dart and transfers them through a MethodChannel to native
  storage. This is unresolved; do not claim an all-native directional-key lifecycle or that directional keys never
  enter Dart. The native envelope use path does not return a key or bearer credential to Dart.
- On mismatch, expiry, invalid completion, cancellation, or unrecoverable local state, delete pending secret,
  ephemeral key, directional keys, SAS, QR, nonce, ciphertext. Pin rotation/loss is not silent recovery.
- Never put QR, SAS, ciphertext, directional keys, private keys, completion bodies, active envelope plaintext,
  or raw SMS in logs, analytics, crash reports, notifications, screenshots, or backups. Every pairing HTTP
  response is `Cache-Control: private, no-store`.
