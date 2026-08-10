# Native Android financial-SMS receiver release gates

## Why

The repository now contains a minimal `RECEIVE_SMS` receiver and Android Keystore encrypted trusted-sender inbox. Google Play exception approval, device evidence and storage-failure UX still gate production release.

## Scope

- Submit and obtain Google Play approval for the SMS-based financial-transactions / SMS-based money-management exception. Do not claim approval from manifest or test evidence.
- Verify prominent disclosure, `RECEIVE_SMS` runtime prompt, denial, permanent-denial/settings, reinstall, and permission-revocation on supported devices. There is no default-SMS role flow.
- Receive only platform-authorized SMS paths; normalize OS metadata; enforce exact trusted sender before parsing; enforce 4 KiB/eight-segment/31-day bounds; never trust sender text inside body.
- Audit the narrow serialized bridge, pre-enqueue three-second `outcome_unknown` deadline, 4.5-second broadcast watchdog, nonblocking capture-miss signal, exact sender normalization, 4 KiB/eight-segment/31-day bounds, 500-record/2 MiB inbox capacity, append-only encrypted decision replay, generation-checked permission/foreground/unlock drain, and durable decision-before-delete flow. Test process kill during the bounded miss-signal attempt and scheduler saturation after immediate broadcast finish; the current design explicitly does not guarantee that signal survives process death or unavailable storage. No raw SMS in logs, analytics or sync.
- Define authenticated server acknowledgement before adding decision-journal pruning. This slice exposes a bounded decision export/status and deliberately has no local decision delete API.
- Add instrumented Keystore tests for key invalidation, corruption, low-storage/write failure, directory-fsync behavior, reinstall, retention and loss. Prove both creation orders for the separately inventoried rules and inbox/journal Keystore domains on real devices, then invalidate each alias independently. Power-cut test the persistent journal-recovery marker before every journal ciphertext quarantine, including tombstones; the application has no marker-clear API. Current JVM tests exercise those first-use orders, same-domain fail-closed inventory, repeated/restarted recovery, injectable AES-GCM/storage boundaries and marker-write/rename/directory-sync-before-quarantine ordering, but are not power-loss or Android Keystore proof on a device. Any final recovery-required state, whether caused by journal, rules, or raw-inbox corruption or key loss, publishes null decision count/byte fields. Storage is Android Keystore AES-GCM over encrypted per-record files in `noBackupFilesDir`; it is not SQLite/shared-preference encryption.
- Integrate verified local Gemma 4/LiteRT runtime only after model provenance, capability/resource budgets, cancellation, circuit breaker, redaction and schema validation independently tested. No background upload.

## Acceptance

1. Instrumented tests: deny, permanent deny/revocation, reboot/process-death, malformed/oversized SMS, spoofed sender body, trusted sender, duplicate delivery, model timeout, and template review.
2. Security review: no restricted-permission deception, raw-SMS telemetry, unencrypted-at-rest claim, event/credit from model output.
3. Real-device screenshots/video: prominent disclosure, Android grant/cancellation/settings, process-dead trusted delivery, untrusted exclusion, lifecycle relock, unlock drain and durable review decision.
4. Device/storage-loss behavior matches mobile PRD and creates no false payment confirmation.
