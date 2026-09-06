# Issue: Rotate enrolled device identity and install root

## Problem

Current v2 pairing supports verified-operator revocation and SAS-confirmed re-pair rotation. It immediately
revokes all existing paired installations for the organization before issuing fresh pairwise keys and a new
credential; old credentials have no overlap window. This preserves one active paired installation generation
and does not provide a multi-device protocol.

## Future scope (not delivered)

- Define authenticated rotate/begin and rotate/complete contracts with old-and-new key possession.
- Rotate device Ed25519 identity and per-install secret independently; keep explicit key versions.
- Do not add overlap to the current one-active-generation contract without a separately approved protocol
  revision, recovery model, and cross-engine concurrency proof.
- Make retries idempotent and recovery explicit when the response is lost after commit.
- Define any lost-device re-enrollment detail beyond the current administrator revoke plus fresh QR flow, without secrets or raw SMS.
- Specify lost-device recovery requiring a separately authorized administrator or a fresh physical QR.

## Acceptance criteria

- Laravel passes the runtime-neutral black-box rotation fixtures.
- SQLite, MySQL, and PostgreSQL adapters pass concurrent rotate/replay/crash tests when declared supported.
- Old credentials fail immediately after the documented re-pair replacement; cross-tenant and wrong-install rotation fail without
  enumeration.
- Rotation secrets are protected through `KeyProtector`; plaintext never appears in logs or problems.

## Out of scope

Provider credential rotation, automatic account recovery without an administrator, and recovery after all
independent authorities are lost.
