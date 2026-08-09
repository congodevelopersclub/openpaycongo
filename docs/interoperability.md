# Interoperability and shared storage contract

Status: a portability contract for future implementations, not a claim that current SQLite data is portable.

Any Go, Node, PHP, or other implementation may own the same logical storage contract: immutable `ledger_events`, idempotency outcomes, sync cursors/acknowledgements, parser proposals/approvals, and derived balance projections. The canonical field names and formats are in [ledger-event.schema.json](ledger-event.schema.json); implementations must preserve them at the API and migration boundary.

SQLite, MySQL, PostgreSQL, and MongoDB may differ physically but must map the same logical fields, uniqueness constraints, immutable-event rule, atomic idempotency replay comparison, and cursor ordering. Mongo deployments require a replica set where transactional event persistence and projection are used. Balance remains a projection derived from immutable events, never a separately authoritative number.

The idempotency unique key is exactly `(tenant_id,idempotency_key)`; digest/result are atomically stored values used for replay comparison, not part of the unique key. Mongo replica-set transactions are mandatory for supported Mongo adapters, and `/readyz` fails when this capability is absent. Concrete framework boundaries are Go chi handlers, Node Fastify routes, Laravel API routes, and a shared black-box HTTP harness that runs the same contract, idempotency, adapter, export, and recovery cases against each implementation.

Migration/export tooling must round-trip canonical events, record source/database/version, verify digests and counts, and support rollback to a read-only previous projection. Cross-backend conformance tests must run the same positive/negative contract fixtures and idempotency scenarios against every supported adapter.
