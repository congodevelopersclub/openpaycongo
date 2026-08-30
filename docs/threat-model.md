# Security threat model and privacy lifecycle

## Status and reading guide

This document is an open-source-safe inventory of repository evidence as of its commit. It is **not production-ready**, does not authorize deployment, and does not substitute for a maintainer-approved security, privacy, identity, release, or incident policy.

- **Verified repository fact** means the cited source describes a checked-in contract, implementation, or test.
- **Planned requirement** means the source says what a future implementation must do; it is not evidence that it is deployed.
- **Pending maintainer authority** identifies a decision that contributors and automation must not choose.

No examples in this document contain personal data, usable credentials, private keys, raw message contents, or enrollment material.

## Verified repository facts

- The root README says the Android application and canonical Laravel server are incomplete prototypes and must not process real payments or real SMS data ([README](../README.md)).
- Canonical public events exclude raw SMS. The event schema rejects fields outside the published shape, and the architecture says `tenant_id` is derived from authenticated server state rather than accepted from request JSON ([ledger event schema](ledger-event.schema.json), [architecture](architecture.md)).
- The Android prototype stores trusted local evidence under Android Keystore-backed encryption and treats key invalidation or journal corruption as recovery-required rather than silently continuing ([mobile PRD](prd-mobile.md), [EncryptedSmsVault](../android-client/android/app/src/main/kotlin/com/example/opencongopay/sms/EncryptedSmsVault.kt)).
- The pairing protocol binds an authenticated administrator ceremony to a bounded QR, uses protected ephemeral/private material, and requires `private, no-store` pairing responses. It explicitly does not protect a compromised hosting edge, administrator UI, or OAuth session ([ADR 004](adr-004-secure-device-enrollment.md)).
- The canonical Laravel implementation and Android client are not evidence of release signing, deployable server image, or completed authentication lifecycle ([README](../README.md)).
- **Prototype warning:** the canonical Laravel server does not yet establish production authentication, secret storage, telemetry retention, or deployment readiness. It must not process real data.
- **Legacy Flutter encryption removal:** this change removes only the unused
  plaintext `paymentdetail` SQLite helper and its empty encryption placeholder.
  It does not erase any pre-existing database file. The native inbox is
  encrypted, but the current durable payment outbox stores scope identifiers,
  idempotency keys, and payment-envelope data in plaintext SQLite/JSON;
  encrypting or safely migrating that storage remains a release blocker. Its
  aggregate sync telemetry exposes only a count, never credentials, scope
  identifiers, provider evidence, money, or idempotency material.
- Flutter console telemetry is checked in, but no repository evidence proves a production telemetry redaction/sink/retention policy ([Flutter telemetry](../android-client/lib/services/Telemetry/telemetry.dart)).
- CI builds checked-in contract, Laravel, and Android paths in Docker; the Android debug artifact is retained for seven days and is not a release artifact ([CI workflow](../.github/workflows/ci.yml), [README](../README.md)).

## Assets, actors, and trust boundaries

| Asset or boundary | Actors | Current evidence and boundary |
| --- | --- | --- |
| Raw trusted SMS evidence | Device owner; Android OS; malicious sender/app | The newer mobile slice describes a Keystore-backed inbox where raw SMS remains local and is excluded from canonical public events. |
| Canonical immutable event | Enrolled device, merchant integration, backend | Public input must not choose tenant or replica identity; tenant_id is derived from authenticated claims or enrolled-device state before authorization and idempotency checks. |
| Local encryption keys and recovery markers | Device owner; Android Keystore; device attacker | The Android SMS vault implements Keystore-backed domains and recovery-required state. Device loss, key invalidation, and storage corruption remain recovery boundaries, not silent success paths. |
| Pairing QR and derived device material | Authenticated administrator; phone; backend; attacker with physical/edge/UI access | QR is temporary bearer material. The short-authentication-code ceremony detects mismatch only when the administrator display and phone display are authentic and compared. |
| Administrator, merchant, mobile, and service identity | Maintainer-selected issuer; clients; reverse proxy | OAuth-style scopes are contract vocabulary only. Issuer, claims, audiences, client registration, rotation, revocation, outage, and recovery policy are pending. |
| Repository, CI, dependencies, and artifacts | Contributors; maintainers; CI provider; supply-chain attacker | Workflows are least-privilege read-only and actions are pinned, but scanner thresholds, exception handling, SBOM/provenance/signing, and release authority are pending. |

## Abuse cases and current controls

| Abuse case | Current control or requirement | Residual risk / evidence gap |
| --- | --- | --- |
| Untrusted sender or parser fabricates payment evidence | The mobile design requires an exact approved sender and active parser; parser proposals cannot create ledger events or upgrade sender trust ([ADR 003](adr-003-parser-proposal-trust.md)). | Sender-policy ownership, production parser review, and real-device behavior remain release work. |
| Client supplies another tenant, wallet, or replica | The canonical contract excludes tenant identity from event input; architecture requires verified identity before authorization. | Production issuer and claim validation are not yet approved or implemented across runtimes. |
| Same idempotency key is reused with different content | Canonical architecture requires an atomic tenant/idempotency key plus digest check, returning conflict for changed reuse. | Runtime/datastore adapters and black-box matrix evidence remain incomplete. |
| Pairing QR interception, UI compromise, or key-material disclosure | ADR 004 constrains QR fields, cryptographic transcript, key destruction, no-store response policy, and administrator comparison. | Compromised edge, administrator UI, or OAuth session is explicitly outside the current guarantee; rotation and multi-device recovery are future work. |
| Lost/invalidate device key or corrupt journal is mistaken for healthy state | The mobile storage design uses recovery-required markers and reports recovery instead of a false record count. | Real-device power-loss and recovery rehearsal are still required. |
| Secrets or raw SMS leak through public evidence | Repository documentation forbids raw SMS, credentials, and wallet databases; canonical events omit raw SMS. | Telemetry retention, exporter configuration, and incident-log access policy are not yet approved. |
| Unsupported endpoint or local database is used with real data | README prohibits real payments and SMS. The removed legacy plaintext path must not be restored. | Maintainers must keep unsupported prototype storage out of supported releases. |
| Vulnerable dependency or mutable build input reaches a release | CI pins actions and toolchains; `SECURITY.md` makes confirmed Critical and High findings release blockers and defines response roles. | Exception expiry, advisory sources, SBOM/provenance, signing, and production release authority remain incomplete evidence. |

## Privacy lifecycle

| Data category | Collection and storage fact | Sharing/export fact | Retention, deletion, backup, and access authority |
| --- | --- | --- | --- |
| Raw SMS | The mobile design keeps trusted raw content in an encrypted on-device inbox and rejects untrusted content before persistence. | Canonical event design excludes raw SMS; plaintext prototype persistence is not a permitted sharing model. | Pending maintainer authority. The prototype does not establish an approved retention or deletion schedule. |
| Local review decisions and recovery state | The vault stores encrypted state and recovery-required blocks normal mutation/export claims. | Current exports are diagnostic/prototype behavior, not a production data-rights implementation. | Pending maintainer authority for retention, deletion, support access, backups, and recovery assistance. |
| Canonical ledger event and projections | The planned backend stores immutable events and derives projections; tenant identity is server-injected. | Planned recovery exports include ordered digest/count information and exclude keys, bearers, QR, short code, and raw SMS ([reliability](reliability.md)). | Pending maintainer authority for retention, lawful basis, deletion limits for immutable records, backups, restore access, and audit access. |
| Operational telemetry and CI evidence | Current workflow retains a debug APK for seven days. Repository sources describe no approved telemetry service or production logging policy. | Public issues and PRs must use synthetic, redacted evidence. | Pending maintainer authority for telemetry fields, sampling, retention, access, incident export, and deletion. |

## Recovery and residual-risk statement

The local-first ADR states that recovery needs durable device state, backend replication, and a third authority for simultaneous device and server loss. Simultaneous device and server loss therefore has no proven complete recovery path in the current repository. It must be communicated as a residual risk until maintainers approve and test an independent recovery authority, backup, restore, and user-notification process.

## Pending maintainer authority

The following are **not yet approved** and must be decided by maintainers before a production claim or enforcement implementation:

1. Accountable security, privacy, identity, release, and incident-response roles plus backup escalation.
2. OAuth/OIDC issuer, claim matrix, audiences, client types, key rotation, token expiry, revocation, logout, outage behavior, and break-glass/recovery authority.
3. Privacy basis, retention/deletion/export/backup/restore rules, telemetry and crash-data policy, audit access, and user-support process.
4. Enabling and verifying the GitHub private vulnerability-reporting route. `SECURITY.md` defines the response targets, coordinated disclosure, and emergency procedure, but the repository setting is currently disabled.
5. Advisory sources, exception evidence/expiry, dependency cadence, SBOM/provenance/signing, and production release authority.
6. Production hosting, deployment, artifact, and release approval authority.
7. Canonical mobile storage ownership and a policy for preventing reintroduction of legacy plaintext prototype paths.

Until those choices exist, contributors must use synthetic fixtures, avoid sensitive data, and treat absent policy as a release blocker rather than permission to choose a default.

## Review and update triggers

Update this model when the identity ADR, threat/privacy policy, vulnerability policy, datastore/runtime adapters, telemetry/export design, recovery plan, or release process changes. Each update should link its code or contract evidence and state whether it changes a verified fact, a planned requirement, or a maintainer decision.
