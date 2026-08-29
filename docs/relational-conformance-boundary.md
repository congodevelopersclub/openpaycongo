# Canonical relational conformance boundary

## Status

This packet prepares part of issue #21 from existing public contract evidence.
It is not a relational schema, migration, or database-adapter implementation.
The canonical migration revision, complete logical entity mapping, physical types,
checksums, and supported adapter matrix are not yet defined. It does not claim a
production-ready adapter.

## Verified public invariants

- Canonical events exclude client-supplied tenant and replica identity; verified
  authority supplies those facts before wallet membership and idempotency lookup.
- Event payload digests are SHA-256 over UTF-8 RFC 8785 canonical JSON with the
  digest member omitted; this is independent of ORM and SQL dialect.
- Idempotency stores the original digest and result atomically under
  `UNIQUE(tenant_id,idempotency_key)`. A matching replay returns the original
  result; a changed digest conflicts.
- Canonical event uniqueness also includes `(tenant_id,provider,reference)` and
  `(tenant_id,replica_id,device_sequence)`. Device sequence is a bounded decimal
  string, and money is bounded integer/decimal-string semantics, never binary
  floating point.
- Existing portability documentation treats balances as projections derived from
  immutable events, not independently mutable authority.

## Required schema mapping

The approved machine-readable mapping must define every logical entity and field,
canonical encoding, nullability, primary/unique/check and foreign-key rule,
lookup/index need, and migration revision. It must distinguish domain invariants
from engine-specific locking and physical representation.

It must cover at least immutable events, idempotency outcomes, cursor and
acknowledgement state, projection generation, enrollment/pairing records, and
failure-latch/recovery state. An unknown revision or newer revision must be rejected before
exposing datastore or runtime details publicly.

## Conformance fixture gate

After the mapping is approved, shared fixtures must demonstrate exact replay,
changed replay, concurrent completion, monotonic acknowledgement, slow-old/
fast-new projection compare-and-set, failure latch, canonical encoding, overflow,
unknown field, missing constraint/index, and checksum drift negatives. The same
fixtures must run in Docker against SQLite and empty PostgreSQL/MySQL instances
without claiming those adapters are production-ready.

Recovery/export fixtures must bind ordered event counts and digests, non-secret
enrollment audit, cursor/acknowledgement state, projection version, and migration
checksums while excluding keys, bearer tokens, QR material, short codes, and raw
SMS.

## Adapter and migration boundary

SQLite, PostgreSQL, and MySQL may differ physically only after preserving
the approved logical mapping and one-winner invariants. Existing SQLite code is
legacy/prototype evidence, not confirmation of the canonical revision. Migrations
must be additive and checksummed; drifted or missing constraints/indexes close
readiness. Rollback keeps the pre-migration database read-only and restores only
from verified backup; destructive down migrations are out of scope.
