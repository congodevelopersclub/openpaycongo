# Interoperability and shared storage contract

Status: a relational conformance contract for Congo OpenPay Server, not a claim that every planned datastore is implemented.

The Laravel server owns the logical storage contract: immutable `ledger_events`, idempotency outcomes, sync cursors/acknowledgements, parser proposals/approvals, and derived balance projections. The canonical field names and formats are in [ledger-event.schema.json](ledger-event.schema.json); migrations must preserve them at the API boundary.

SQLite, MySQL, and PostgreSQL may differ physically but must map the same logical fields, uniqueness constraints, immutable-event rule, atomic idempotency replay comparison, and cursor ordering. Balance remains a projection derived from immutable events, never a separately authoritative number.

The idempotency unique key is exactly `(tenant_id,idempotency_key)`; digest/result are atomically stored values used for replay comparison, not part of the unique key. Laravel API routes, migrations, and Docker tests are the canonical implementation boundary.

Migration/export tooling must round-trip canonical events, record source/database/version, verify digests and counts, and support rollback to a read-only previous projection. Laravel tests must run the positive and negative contract fixtures and idempotency scenarios on each declared supported database.

Pairing adapters map the same intent, bounded-attempt, pending-confirmation, terminal-confirmation audit, and device logical records. Before decrypting a proof, an adapter atomically verifies pending/unexpired/below-bound state and reserves one attempt. Completion compares the request digest, uniquely creates `(tenant_id,install_id)`, persists only the bounded opaque `KeyProtector` result for the install root, caches the encrypted response, consumes the intent, and clears its protected ephemeral key in one transaction while retaining non-secret replay metadata. Expiry/exhaustion cleanup is page-bounded; mismatch/timeout clears the pending root and SAS. Administrator confirmation keys idempotency by `(tenant_id,intent_id,request_id)` and persists verified actor, reason, decision, and server time; first terminal decision wins, exact replay returns it, and every other terminal request conflicts.

SQLite uses one immediate writer transaction; MySQL/PostgreSQL lock the intent row and enforce unique indexes. Congo OpenPay Server may advertise readiness only after concurrent same-intent tests prove bounded proof work, one persisted device, ephemeral-key destruction, replay retention, exact confirmation replay, wrong-tenant rejection, and one winner for match/mismatch races. Laravel must consume the runtime-neutral signed-QR and key-schedule vectors, canonical UTC-second timestamps, discriminated SAS response schema, and `private, no-store` header assertions.
