# Native Android SMS role and Keystore vault

## Why

Flutter UI/domain code can explain capture policy but cannot truthfully implement Android default-SMS role, platform broadcast handling, encrypted durability or Gemma runtime isolation. This issue gates production automatic SMS capture.

## Scope

- Prove product/distribution eligibility for `RoleManager.ROLE_SMS` against current Android and Play policy before prompt. If ineligible, keep automatic capture disabled.
- Build audited native role/onboarding: discover capability, explain purpose, launch role request only from user action, record outcome, handle role loss, expose honest typed state to Flutter. Do not request `READ_SMS` substitute.
- Receive only platform-authorized SMS paths; normalize OS metadata; enforce exact trusted sender before parsing; enforce 4 KiB/eight-segment/31-day bounds; never trust sender text inside body.
- Build narrow versioned Flutter platform bridge with typed errors and contract tests. No raw SMS in logs, analytics or sync.
- Store minimized inbox/outbox evidence in audited encrypted storage backed by Android Keystore. Define key invalidation, backup/restore, lock-screen/auth binding, migration, deletion, corruption and loss behavior. Never call SQLite/shared preferences encrypted merely because app-level code serializes value.
- Integrate verified local Gemma 4/LiteRT runtime only after model provenance, capability/resource budgets, cancellation, circuit breaker, redaction and schema validation independently tested. No background upload.

## Acceptance

1. Instrumented tests: eligible, ineligible, deny, permanent deny/role-loss, reboot/process-death, malformed/oversized SMS, spoofed sender body, trusted sender, model timeout, manual fallback.
2. Security review: no restricted-permission deception, raw-SMS telemetry, unencrypted-at-rest claim, event/credit from model output.
3. Real-device screenshots: informed role explanation, cancellation, unsupported state, manual evidence recovery.
4. Device/storage-loss behavior matches mobile PRD and creates no false payment confirmation.
