# Issue: Rotate enrolled device identity and install root

## Problem

Version 1 enrollment creates a device signing identity and unique per-install secret but intentionally
does not rotate either. Long-lived credentials need bounded, recoverable rotation without reopening the
one-time QR or silently changing tenant/wallet authority.

## Scope

- Define authenticated rotate/begin and rotate/complete contracts with old-and-new key possession.
- Rotate device Ed25519 identity and per-install secret independently; keep explicit key versions.
- Atomically activate the new key, preserve a short bounded overlap only when required, and revoke the old
  key at a recorded server revision.
- Make retries idempotent and recovery explicit when the response is lost after commit.
- Add administrator revoke/re-enrol UX and audit records without secrets or raw SMS.
- Specify lost-device recovery requiring a separately authorized administrator or a fresh physical QR.

## Acceptance criteria

- Go, Node/Fastify, and Laravel implementations pass the same black-box rotation fixtures.
- SQLite, MySQL, PostgreSQL, and Mongo replica-set adapters pass concurrent rotate/replay/crash tests.
- Old credentials fail after the documented overlap; cross-tenant and wrong-install rotation fail without
  enumeration.
- Rotation secrets are protected through `KeyProtector`; plaintext never appears in logs or problems.

## Out of scope

Provider credential rotation, automatic account recovery without an administrator, and recovery after all
independent authorities are lost.
