# Interoperability and shared storage contract

Status: a relational conformance contract for Congo OpenPay Server, not a claim that every planned datastore is implemented.

The Laravel server owns the logical storage contract: immutable `ledger_events`, idempotency outcomes, sync cursors/acknowledgements, parser proposals/approvals, and derived balance projections. The canonical field names and formats are in [ledger-event.schema.json](ledger-event.schema.json); migrations must preserve them at the API boundary.

SQLite, MySQL, and PostgreSQL may differ physically but must map the same logical fields, uniqueness constraints, immutable-event rule, atomic idempotency replay comparison, and cursor ordering. Balance remains a projection derived from immutable events, never a separately authoritative number.

The idempotency unique key is exactly `(tenant_id,idempotency_key)`; digest/result are atomically stored values used for replay comparison, not part of the unique key. Laravel API routes, migrations, and Docker tests are the canonical implementation boundary.

Migration/export tooling must round-trip canonical events, record source/database/version, verify digests and counts, and support rollback to a read-only previous projection. Laravel tests must run the positive and negative contract fixtures and idempotency scenarios on each declared supported database.

Pairing v2 adapters map a one-time `PairingIntent` and pending-confirmation material. Under one locked transaction server validates pending/unexpired intent, derives `crypto_kx` directional keys, decrypts QR-secret envelope, persists Laravel-encrypted pending directional keys/SAS, stores exact replay response, and clears protected server seed plus QR-secret digest. Exact identical retry returns stored encrypted `201`; altered or other consumed request is unavailable. Completion never creates `SourceInstallation`, status bearer, or active device authority in this slice.

SQLite uses one immediate writer transaction; MySQL/PostgreSQL lock intent row and enforce unique indexes. Before readiness claim, Laravel tests must prove one pairing outcome, protected seed/secret destruction, exact replay retention, altered replay rejection, generic unavailable response, canonical UTC-second timestamps, `private, no-store`, and PHP/Flutter `pairing-v2.fixture.json` interoperability. Administrator confirmation, activation, counters, rotation, recovery, and mobile envelopes need independent conformance before inclusion.
