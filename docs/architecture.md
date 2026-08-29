# Canonical architecture

Status: planned architecture, not fully implemented by the canonical server.

The mobile client is the local-first authority for the payment inbox/outbox it has durably recorded. The backend is the authoritative replicated immutable ledger for acknowledged events and derives balances from that ledger. Neither a displayed balance nor a parsed SMS is an independently mutable source of truth.

The public sync boundary is `POST /v1/sync/push`, `GET /v1/sync/pull`, and `POST /v1/sync/ack`. A merchant integration pushes one canonical public event: UUIDv7 event identity, wallet identity, provider/reference, UTC receipt timestamps, parser/source, device sequence, idempotency key, and digest. Persisted records add server-injected tenant and replica identity. Raw SMS remains local and is never sent in the public payload.

## Normative identity, money, and idempotency rules

The client never submits `tenant_id` or `replica_id`: the service derives tenant, authenticated enrolled replica, and allowed wallets from credentials before wallet-membership validation and before idempotency lookup. Storage and recovery exports include those server-injected fields. V1 push accepts exactly one event, never a batch. `device_sequence` is a one-to-twenty-digit decimal string scoped by tenant and replica; gaps and out-of-order arrival are valid, while pull order is server acceptance order.

The currency-scale registry is versioned: CDF=2 and USD=2. Display decimal `6870.00` CDF becomes `687000` by rejecting signs/grouping/excess fraction, right-padding to its scale, and parsing the resulting digits without floating point. `amount_minor` is a positive 1–20 digit integer portable to `DECIMAL(20,0)`.

`payload_digest` is SHA-256 of UTF-8 RFC 8785/JCS canonical JSON of the public event with `payload_digest` omitted; timestamps are UTC (`Z`). Atomically store the original digest and result under `UNIQUE(tenant_id,idempotency_key)`; same digest replays that result, changed digest returns 409. Also enforce `UNIQUE(tenant_id,provider,reference)` and `UNIQUE(tenant_id,replica_id,device_sequence)`.

Debits require `expected_wallet_revision` as a 1–20 digit decimal string, verify it with the balance projection transaction, and must not make balance negative. Stale revision or insufficient funds returns 409.

Mobile/user authorization uses authorization code plus PKCE and an enrolled device; merchant/server integration uses client credentials. Claims carry tenant, replica (where enrolled), scopes, and wallet membership; revocation is checked before every operation. A mobile app never ships a broad client secret.

Services authorize each request by tenant and scope, validate the public contract, persist the immutable event before projection, and publish cursor-based changes. Replays with the same idempotency key and digest return the original result; the same key with a different digest returns `409`.

See [interoperability](interoperability.md), [reliability](reliability.md), and the canonical [OpenAPI contract](openapi.yaml).

## Enrollment boundary

Device enrollment follows [ADR 004](adr-004-secure-device-enrollment.md). The canonical Laravel application owns the typed pairing domain and application service, with clock, randomness, identity signer, `KeyProtector`, and atomic repository ports. Any future administration experience belongs inside the Laravel application and must not perform server cryptography or receive persisted secrets.
