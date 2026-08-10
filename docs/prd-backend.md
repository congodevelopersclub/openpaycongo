# PRD: Replicated immutable ledger backend

## Problem Statement

Mobile devices need a portable, safe backend that can accept retries, replicate across devices, preserve auditability, and be implemented in more than one language/database without changing financial meaning. The current Go server is a legacy prototype and does not provide this contract.

## Solution

Provide an authenticated canonical event API with immutable persistence, idempotent push, cursor pull, acknowledgement, derived projections, operational endpoints, and a shared logical storage contract across SQLite, MySQL, PostgreSQL, and MongoDB.

## User Stories

1. As a mobile client, I want to push one canonical event, so that the backend can persist an immutable ledger fact.
2. As a merchant integration, I want the same one-event push contract, so that I do not need a separate accounting API.
3. As a client retrying after timeout, I want the original success result returned for the same key and digest, so that retries are safe.
4. As a client with changed evidence, I want a `409` problem response for the same key and different digest, so that conflicts are visible rather than overwritten.
5. As a tenant administrator, I want scopes to limit writes, reads, and acknowledgements, so that devices cannot exceed their authority.
6. As a device, I want cursor-based pull pages, so that I can resume replication without missing or duplicating history.
7. As a device, I want acknowledgement recorded separately from pull, so that server retention and device application state are observable.
8. As an operator, I want balances derived from immutable events, so that an editable balance cannot diverge from history.
9. As an operator, I want health, readiness, and version endpoints, so that deployment automation distinguishes liveness from dependency readiness.
10. As a security reviewer, I want RFC 9457 errors and no raw SMS in public payloads, so that failure behavior and privacy boundaries are consistent.
11. As a portability owner, I want an implementation in Go, Node, PHP, or another language to use one logical schema, so that ownership can change without data reinterpretation.
12. As a database operator, I want backend-specific transactional rules documented, so that Mongo replica-set requirements are not discovered during an incident.
13. As a recovery operator, I want export/import verification by event count and digest, so that migrations do not silently corrupt the ledger.
14. As a CI owner, I want every adapter to pass the same contract fixtures and idempotency cases, so that storage parity is continuously checked.
15. As a release owner, I want signed artifacts, SBOM/provenance, scans, migration rehearsal, and readiness evidence, so that a green build is not mistaken for a safe release.
16. As an incident responder, I want third-authority recovery limits documented, so that simultaneous device/server loss is handled truthfully.

## Implementation Decisions

- Persist each valid event before any balance projection or external side effect.
- Use UUIDv7 event identities, tenant and wallet identifiers, decimal-string minor amounts, ISO currency, provider/reference, occurrence/receipt timestamps, parser/source metadata, sequence, idempotency key, and SHA-256 payload digest.
- Reject raw SMS and unknown public fields from canonical event payloads.
- Bind idempotency to tenant plus key; compare digest before replaying the original result.
- Enforce authorization scopes at the endpoint boundary and provide RFC 9457 problem details for validation, authorization, conflict, and readiness errors.
- Treat all database adapters as mappings of one logical schema and invariant set. Every supported Mongo runtime requires a replica set plus transactions; `/readyz` fails otherwise.
- Make event migrations additive, exportable, digest-verifiable, and reversible to a read-only prior projection.

## Public Module Interfaces

- Push accepts one authorized canonical event and returns persisted, replayed, or conflict outcome with a cursor.
- Pull accepts an authorized cursor and bounded page request and returns ordered immutable events and a next cursor.
- Acknowledgement accepts an authorized applied cursor and returns no content on success.
- Projection accepts ledger events and produces a derived balance/read model without changing event history.
- Adapter storage accepts canonical events, idempotency lookups, cursors, acknowledgements, and migrations while preserving the shared invariants.
- Operational status exposes liveness, readiness/dependency state, and build/contract version independently of business authorization.

## Testing Decisions

- Exercise behavior through HTTP/public contract tests: valid push, replay, changed-digest conflict, unauthorized scope, pull ordering/resume, acknowledgement, RFC 9457 errors, and operational endpoint semantics.
- Run the canonical OpenAPI/schema positive and negative fixtures in Docker. Reuse them unchanged for every database adapter.
- Test migrations, export/import digest/count checks, crash after persistence before projection, and recovery from each documented loss scenario.
- Run race/concurrency tests around duplicate idempotency keys and projection rebuilding.
- Release CI validates pinned dependencies, SBOM/provenance, vulnerability/secret scanning, signed artifacts, a database-adapter matrix, and post-deploy readiness.

## Out of Scope

- Reconstructing a ledger after both backend and all client copies are lost without an independent third authority.
- Provider-specific settlement guarantees, fraud scoring, and automatic parser approval.
- Claiming production compatibility from the existing Go/SQLite prototype.

## Further Notes

The API is a portability boundary, not an instruction to expose a database directly. A successful push means durable ledger persistence under the documented authorization/idempotency rules; it does not alone prove provider settlement.

## User Stories (continued)

17. As a client, I want tenant derived from my token, so that tenant spoofing is impossible.
18. As a client, I want wallet membership checked before idempotency, so that replay cannot cross wallets.
19. As an enrolled device, I want replica identity derived by the server, so that I cannot impersonate another device.
20. As a client, I want 1–20 digit string sequence values, so that integer precision is portable.
21. As an operator, I want gaps/out-of-order arrivals accepted, so that offline devices remain usable.
22. As a client, I want pull ordered by server acceptance, so that cursors are stable.
23. As a merchant, I want V1 to reject batches clearly, so that transaction semantics are explicit.
24. As a finance user, I want CDF/USD scale registry conversion without floats, so that 6870.00 CDF is 687000.
25. As an adapter owner, I want DECIMAL(20,0) bounds, so that databases agree.
26. As a client, I want provider-reference duplicate protection, so that a provider receipt cannot credit twice.
27. As a client, I want debit revision conflicts, so that stale spending cannot overdraw.
28. As a client, I want insufficient funds conflicts, so that negative balance is impossible.
29. As a mobile user, I want PKCE authorization and enrolled-device claims, so that no broad secret ships in the app.
30. As a merchant server, I want client credentials, so that server integrations have separate revocation.
31. As an operator, I want revoked membership denied immediately, so that access removal is effective.
32. As a Mongo operator, I want replica-set transactions mandatory, so that projections are atomic.
33. As a deployer, I want unsupported topology make readiness fail, so that unsafe writes are not admitted.
34. As a client, I want invalid/future ack cursors rejected and old acks idempotent, so that sync state is sound.
35. As an auditor, I want NDJSON manifest/order/digest/checksum recovery exports, so that restore is verifiable.
36. As an operator, I want projection rebuild and cursor invalidation/reissue after restore, so that stale cursors cannot corrupt sync.
37. As a security reviewer, I want problems/logs/traces body-free, so that raw SMS and secrets never echo.
38. As an implementer, I want Go chi, Node Fastify, and Laravel routes tested by one black-box harness, so that framework changes preserve meaning.

## Secure device enrollment slice

39. As a tenant administrator, I want a short-lived signed QR, so that physical access bootstraps exactly one device without exposing tenant claims.
40. As a mobile user, I want the app to verify HTTPS and the pairing transcript, so that Diffie-Hellman is never mistaken for authentication.
41. As an operator, I want one-time consumption and an exact encrypted replay result, so that a timeout cannot create a second device.
42. As a security reviewer, I want bounded expiry/attempts and generic unavailable errors, so that screenshots, brute force, and enrollment enumeration are constrained.
43. As an administrator, I want the same transcript-derived short code shown on my authenticated screen and phone, so that first-use substitution cannot activate a device.
44. As an operator, I want unique completion reservations separated from completed invalid-proof attempts, so that bounded concurrent KMS outages neither exhaust the client's proof budget nor delete a recoverable intent key.

The normative protocol is [ADR 004](adr-004-secure-device-enrollment.md). The active slice implements the Go typed domain/application core and deterministic ports. It deliberately has no HTTP or SQLite adapter: the legacy store cannot yet prove atomic intent consumption, unique tenant/install identity, pending administrator confirmation, cached replay response, and protected-root persistence. Node/Fastify, Laravel, shared Preact administration/confirmation, and key rotation are subsequent parity slices.

The QR references the long-lived OpenPay enrollment-signing identity, never CDN/TLS SPKI, but a key delivered only inside that QR is not independent authentication. Authenticated administrator context plus mandatory short-code confirmation provides the physical trust step. The hosting edge, administrator UI delivery, and OAuth session are trusted during bootstrap; compromise of any of them can replace the QR or authorize an attacker. Device signatures and request MACs remain portable across direct container, Cloudflare, and Vercel hosting after activation, but no edge-compromise resistance is claimed.

### Mobile pairing acceptance

- The app rejects unknown QR fields, non-HTTPS or non-canonical endpoints, unsupported versions/suites,
  non-UTC-second expiry, expired intents, and malformed fixed-size values before performing key agreement.
- Before consulting continuity/trust state, the app requires
  `SHA-256(enrollment_signing_public_key) == enrollment_signing_fingerprint`, then verifies the Ed25519
  signature over the exact canonical QR transcript. The shared signed-QR vector and every signed-field
  mutation must pass on Android and any future mobile implementation.
- The signed QR carries `first_use_requires_sas` or `pinned_continuity`. Pinned mode requires an existing
  matching fingerprint. First use is provisional physical-QR bootstrap and can never activate before the
  mandatory independently compared SAS. Missing pins and signing-key rotation require a new authenticated
  first-use/SAS ceremony; silent pin replacement is forbidden.
- For each accepted intent the app generates a fresh X25519 keypair and a cryptographically random 96-bit
  AES-GCM nonce. It never reuses a nonce with the same derived key. RNG failure aborts pairing. It separately
  creates or loads a non-exportable long-term Ed25519 device-signing key; the ephemeral X25519 key never
  substitutes for device authorship.
- The app derives the labeled `c2s`, `s2c-aead`, `s2c-confirm`, `install-root`, and unbiased six-digit SAS
  values from the canonical transcript. It verifies response AEAD and key confirmation before accepting the
  server result. It never sends or receives the install root.
- The install root is stored as pending only in Keystore-backed secure storage. Pending material cannot sign
  in, MAC requests, or authorize sync. The phone must display the derived SAS and activation requires an
  authenticated administrator to report an exact display match; mismatch revokes pairing and deletes pending
  root material on both sides.
- An exact completion retry reuses the exact saved request bytes, client ephemeral key, and nonce. It must not
  re-encrypt changed plaintext under the same key/nonce. If the app crashes before durably saving that retry
  state, it discards the pending root and requires a new QR rather than guessing recovery state.
- If the phone is offline before completion, expiry ends the attempt and pending material is deleted. If it
  receives `pending_confirmation` and then goes offline, it keeps the root unusable, keeps showing the SAS,
  and reconciles authenticated state when online; `revoked` or `expired` deletes the root. After activation,
  later server revocation likewise makes the root unusable and removes it according to platform guarantees.
- The encrypted completion response carries a random 256-bit pairing-status bearer whose digest is persisted.
  Over HTTPS the phone uses it, without administrator OAuth, to read pending/terminal state and idempotently
  acknowledge only the exact terminal state. It authorizes no ledger or application operation. Wrong bearers
  and all unavailable completion cases return one fixed 404 problem with no detail or category oracle.
- QR, SAS, ciphertext, roots, private keys, and completion bodies never enter analytics, crash reports, logs,
  notifications, backups, or screenshots retained by the app. Administrator issue/read/confirm responses are
  `private, no-store`; every other pairing success and error carries the same cache directive, and the UI
  clears pairing material when leaving the flow.
