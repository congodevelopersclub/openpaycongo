# ADR 004: Non-ratcheting encrypted mobile enrollment

Status: accepted.

This ADR is pairing contract v2. Deleted v1 `X25519-HKDF-SHA256-AES-256-GCM+Ed25519` schemas, vectors, proof, response, key-schedule files are not alternatives.

## Decision

Pair by physical QR plus six-digit Short Authentication String (SAS). QR is out-of-band bootstrap material. Completion uses one libsodium key-exchange API plus XChaCha20-Poly1305-IETF. Later active mobile traffic uses directional encrypted envelopes. No ratchet.

Server: PHP ext-sodium. Mobile: maintained Sodium binding. Both use `crypto_kx` session-key APIs. Do not implement raw X25519 scalar multiplication, custom HKDF, custom nonce derivation, OpenSSL wire crypto, Laravel `Crypt`, or Composer crypto package for protocol encryption.

QR issue and completion still use HTTPS. HTTPS protects endpoint routing and ordinary transport exposure; pairing and later mobile envelopes protect inner content from TLS terminator. Outer envelopes expose timing, size, route, installation-routing metadata.

## Bootstrap trust and limits

Authenticated administrator starts intent then physically presents QR. QR contains no organization id, customer data, API credential, SAS, or private key. Server derives organization from administrator session. QR must never enter logs, analytics, telemetry, crash reports, browser history, retained screenshots, notifications, or backups.

QR signature detects modification and continuity-pin mismatch. It is not independent authentication when signing key arrives inside QR. `first_use_requires_sas` stays provisional until administrator and phone compare same SAS. `pinned_continuity` additionally requires existing matching pin. Existing pin cannot silently downgrade. Compromised hosting edge, administrator UI, administrator session, or physical QR display can subvert bootstrap. No forward secrecy, post-compromise recovery, device-provenance, multi-device recovery, or edge-compromise-resistance claim.

One-time private material and QR secret must be destroyed after completion, expiry, cancellation, failure cleanup, or revocation. Re-pair/revoke/reset rotates pairwise keys. No per-message ratchet.

## QR v2

QR JSON has exactly fields defined by `pairing-qr.schema.json`:

```json
{
  "version":"2",
  "endpoint":"https://host/v1/pairing/complete",
  "intent_id":"base64url-16-bytes",
  "intent_nonce":"base64url-32-bytes",
  "expires_at":"UTC-second",
  "algorithms":"X25519-crypto_kx-XChaCha20-Poly1305-IETF",
  "enrollment_signing_fingerprint":"base64url-32-bytes",
  "enrollment_signing_public_key":"base64url-32-bytes",
  "server_key_agreement_public_key":"base64url-32-bytes",
  "pairing_secret":"base64url-32-bytes",
  "trust_mode":"first_use_requires_sas|pinned_continuity",
  "signature":"base64url-64-bytes"
}
```

All binary fields are unpadded canonical base64url. Endpoint is lowercase ASCII DNS, optional canonical decimal port, exact `/v1/pairing/complete`; reject IP literals, userinfo, query, fragment, percent encoding, alternate path, trailing slash, upper-case host, non-UTC-second expiry.

Signature is Ed25519 over concatenated unsigned-16-bit-big-endian length plus bytes, in this order:

1. `openpaycongo/pairing/qr`
2. `version`
3. `endpoint`
4. raw `intent_id`
5. raw `intent_nonce`
6. `expires_at`
7. `algorithms`
8. raw `enrollment_signing_public_key`
9. raw `enrollment_signing_fingerprint`
10. raw `server_key_agreement_public_key`
11. raw `pairing_secret`
12. `trust_mode`

Phone checks JSON shape, endpoint, expiry, suite, `SHA-256(signing_public_key) == fingerprint`, signature, trust mode, pin policy before key exchange. `intent_nonce` is signed intent metadata; v2 does not include it in completion or response AEAD AAD.

## Completion v2

Phone creates fresh X25519 keypair then derives directional keys with `crypto_kx_client_session_keys(client_keypair, server_public_key)`. Server rebuilds ephemeral server keypair from protected seed then derives with `sodium_crypto_kx_server_session_keys(server_keypair, client_public_key)`.

The phone transfers the QR secret into a cleanup scope before it asks libsodium to generate that keypair. A key-generation, RNG, or later exchange failure wipes the transferred secret; an exchange cannot be retried with it.

`client_send_key == server_receive_key`. `client_receive_key == server_send_key`. Every directional key is 32 bytes and secret.

Phone sends HTTPS `POST /v1/pairing/complete`:

```json
{
  "intent_id":"base64url-16-bytes",
  "client_public_key":"base64url-32-bytes",
  "nonce":"base64url-24-bytes",
  "ciphertext":"base64url-of-48-decoded-bytes"
}
```

`ciphertext` encrypts exactly raw 32-byte QR `pairing_secret` with XChaCha20-Poly1305-IETF, client-send key, 24-byte random nonce. Completion AAD is unsigned-16-bit-big-endian length plus bytes:

1. `openpaycongo/pairing/complete/v2`
2. raw `intent_id`
3. raw `client_public_key`

Server row-locks pending unexpired intent, validates/decrypts envelope, constant-time compares SHA-256 secret digest, creates CSPRNG zero-padded six-digit SAS, persists encrypted directional keys and SAS, clears protected server seed and secret digest, then returns `201`:

```json
{
  "state":"pending_confirmation",
  "nonce":"base64url-24-bytes",
  "ciphertext":"base64url-of-85-decoded-bytes"
}
```

Result ciphertext encrypts exactly UTF-8 JSON `{"state":"pending_confirmation","short_authentication_code":"000000"}` with server-send key. Response AAD fields:

1. `openpaycongo/pairing/complete-response/v2`
2. raw `intent_id`

Exact retry of saved request bytes returns same stored encrypted `201` response; it does not derive fresh keys, generate new SAS, or create a second pending pairing. Malformed, unknown, expired, altered, exhausted, or otherwise invalid completion returns indistinguishable fixed `404` pairing-unavailable problem. Failed proof authentication atomically consumes one of three per-intent attempts; the final failed proof terminally clears temporary material. The native per-IP completion limiter uses a Laravel cache lock around check-and-consume, atomically admitting at most ten requests per minute. With the default database cache, this is shared across workers. Lock-admission infrastructure failure returns generic no-store `503`; the phone makes its permitted exact retry without learning a failure category. Expiry cleanup locks and clears pages of at most 100 rows per transaction until no due pairing intents remain. Never return secret, directional key, SAS, organization id, failure category, or plaintext envelope. Every pairing response is `Cache-Control: private, no-store`.

For an outcome whose completion status is unknown, the mobile client keeps the one live exchange and makes one immediate retry using the exact immutable four-field request only while the shared 15-second end-to-end budget remains. Unknown means the deadline elapses, the connection or HTTP framing fails, the server returns 408, 429, or 5xx, or a `201` response is oversized, truncated, or malformed before it can be authenticated. It never creates new keys, nonce, or ciphertext for that retry, and both attempts together never exceed the budget. A known non-`201` rejection and a second unknown result fail closed. A process restart before a valid response is not resumable in this initial slice; it destroys the exchange and requires a fresh QR. Durable retry recovery belongs to the recovery follow-up.

## Current implementation boundary

Laravel implements QR v2 issuance, completion/replay, verified-administrator SAS confirmation, and server activation delivery. A matching administrator decision atomically creates one `SourceInstallation`, transfers its encrypted directional keys, creates one scope-limited Sanctum token, seals that token in an immutable activation envelope, and clears the intent's directional keys, SAS, completion replay result, and protected bootstrap material. An exact retry of the same administrator decision is idempotent; a different terminal decision conflicts. A mismatch or expiry creates no installation and clears temporary material.

The mobile runtime verifies the signed QR, then asks the Android native pairing boundary to generate the client keypair, derive directional keys with libsodium, and seal the QR secret. The one-time QR secret crosses the bootstrap MethodChannel once; directional keys never cross it or enter Dart, a BLoC, state, logs, analytics, notifications, screenshots, or backups. Native code retains directional material only in a process-scoped pending exchange until it authenticates the server response and returns only the SAS. It keeps the keys pending through administrator confirmation, then atomically stores the credential, installation identity, and both directions as one Android Keystore-backed active pairing generation. Cancel, failure, replacement, or process restart wipes that pending exchange and requires a fresh QR.

After administrator confirmation, the user explicitly checks activation: the app retrieves only the opaque activation envelope over strict HTTPS without redirects, passes it to the Android native pairing boundary, decrypts it with the pending receiver key using the official libsodium XChaCha20-Poly1305 implementation, and promotes the credential, installation identity, and both directional keys in one no-backup Android Keystore-backed record. This single atomic promotion means a credential-persistence failure leaves the previous active generation intact. This path returns only a redacted outcome; it does not return the receiver key or issued credential. The issued token is never returned to the administrator session.

The first native envelope read after this format change migrates an older separately encrypted credential record and directional-key record only when both authenticate and name the same installation. It serializes active-generation reads, writes, and migration under one process-wide lock. A missing, malformed, unauthenticated, or mismatched legacy record fails closed; it never guesses or partially migrates state.

Laravel now implements the server half of active mobile-envelope deposit transport; the exact contract is [mobile-envelope-v1.md](mobile-envelope-v1.md). Android #211 implements local native sealing: bounded deposit plaintext enters from Dart, a foreground/unlock-gated native vault persists the successor of a Keystore-encrypted no-backup counter before sealing, reads its stored send key and installation identity from one atomically promoted generation, and returns routing-safe envelope fields only. The pure allocator tests restart, exhausted, invalid-state, and write-failure outcomes; Android `AtomicFile` plus `fd.sync()` is the production persistence adapter. This does not prove power-loss behavior on every device/filesystem. Android transport delivery, acknowledgement, revocation, rotation, and durable pairing recovery remain follow-up slices. Response decryption is also out of scope. Do not claim plaintext never enters Dart: the outbound payload originates there. Do not claim a phone is active merely because the server sealed an activation envelope.

## Activation delivery v2

After matching SAS confirmation, the phone may retrieve `GET /v1/pairing/intents/{intent_id}/activation` without a bearer credential. The 128-bit random canonical `intent_id` is routing metadata only; a caller that knows it receives ciphertext, never a credential in cleartext. Unknown, revoked, expired, malformed, or incomplete activation resolves to the same no-store pairing-unavailable response. The response is immutable so an interrupted mobile retrieval can repeat safely:

```json
{"version":2,"nonce":"base64url-24-bytes","ciphertext":"base64url"}
```

`ciphertext` uses the existing server-send / phone-receive `crypto_kx` key and XChaCha20-Poly1305-IETF. Its plaintext is exactly UTF-8 JSON:

```json
{"version":2,"installation_id":"uuid","bearer_token":"sanctum-token"}
```

The activation-response AAD is unsigned-16-bit-big-endian length plus bytes:

1. `0x002b` followed by `openpaycongo/pairing/activation-response/v2` (the exact 43-byte UTF-8 domain field)
2. raw 16-byte `intent_id`

This is a distinct protocol domain, but uses no derived key, custom KDF, alternative AEAD, or duplicated crypto implementation. Laravel stores both protocol ciphertext and nonce with encrypted Eloquent casts; the raw Sanctum token exists only while the server creates and seals the envelope. The server does not log, serialize, return, or retain the token plaintext.

## Active mobile envelope contract

Laravel implements `POST /mobile/envelopes` protocol v1 for encrypted deposit submission. It uses a 24-byte random nonce plus XChaCha20-Poly1305-IETF under the pairing directional keys. No per-message signature: AEAD authenticates the sender holding its directional key. No cleartext business or PII payload reaches Laravel before envelope authentication/decryption. The exact request, response, AAD, counter, failure, and compatibility rules are in [mobile-envelope-v1.md](mobile-envelope-v1.md). PHP feature tests prove valid submission, replay, conflict, tampering, stale counters, and installation retargeting; Android must independently prove compatible native encryption before any Dart transport adapter is released.

## Interoperability evidence

`pairing-v2.fixture.json` contains deterministic test-only QR/signing/KX/AEAD inputs and outputs. `pairing-v2-test-plan.md` is mandatory PHP/Flutter proof plan. Fixture values are never live material. Compatible client verifies QR signature and directional keys, encrypts/decrypts fixture envelopes, rejects one-field tampering.
