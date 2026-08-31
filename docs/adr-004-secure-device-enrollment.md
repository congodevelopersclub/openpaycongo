# ADR 004: Non-ratcheting encrypted mobile enrollment

Status: accepted. Supersedes every earlier pairing contract, vector, schema, and implementation note.

## Scope and trust

Authenticated administrator starts enrollment, physically presents out-of-band QR. QR contains version `2`, canonical HTTPS completion endpoint, 128-bit `intent_id`, UTC expiry, server X25519 public key, fresh 256-bit `pairing_secret`, existing enrollment signature, and trust mode. Signature transcript binds every QR field including `pairing_secret`. No tenant claim, user data, SAS, or application credential. Server binds tenant from issued intent. QR never logged/persisted outside encrypted/hashed fields.

Not ratchet. No forward-secrecy, edge-compromise, device-provenance, or recovery claim. Establishes two directional symmetric keys. Pairing private material/QR secret are one-time: destroy after handoff, failure, expiry, cancellation.

## Version 2 completion envelope

Phone creates X25519 keypair then HTTPS `POST /v1/pairing/complete`:

```json
{"intent_id":"base64url-16-bytes","client_public_key":"base64url-32-bytes","nonce":"base64url-24-bytes","ciphertext":"base64url"}
```

Server calls PHP ext-sodium `sodium_crypto_kx_server_session_keys`; phone calls platform/libsodium `crypto_kx_client_session_keys`. No scalar multiplication, HKDF, OpenSSL, Laravel Crypt, Composer crypto package, or custom key derivation for wire crypto. Client-to-server key protects completion; server-to-client key protects response. `ciphertext` is XChaCha20-Poly1305-IETF encryption of exactly 32-byte QR secret.

Completion AAD exact unsigned-16-bit-length fields: `openpaycongo/pairing/complete/v2`, raw intent id, raw client public key. Strict length bounds. Invalid/expired/replayed/malformed/unknown enrollment -> identical fixed unavailable problem, no details.

Server returns `201` `{state,nonce,ciphertext}`. Nonce = 24 random bytes; ciphertext XChaCha20-Poly1305-IETF under server-to-client key. Response AAD fields: `openpaycongo/pairing/complete-response/v2`, raw intent id. Decrypted JSON exactly `{ "state":"pending_confirmation", "short_authentication_code":"000000" }`. No plaintext secret/private key/directional key/SAS/tenant returned.

## SAS and activation

Server samples SAS with CSPRNG `random_int(0, 999999)`, zero-pads six digits. Phone reads only authenticated response; administrator sees only authenticated confirmation UI. SAS display comparison only: never request input/authentication/log/event/metric/trace/problem detail.

Current slice stops at `pending_confirmation`, never `SourceInstallation`. Confirmation/activation, terminal cleanup, replay/idempotency, and administrator SAS display are pending follow-up slices; no activation claim is made.

## Directional keys and mobile envelopes

Current slice persists directional 32-byte session keys with Laravel encrypted casts on pending pairing material. Transfer to `SourceInstallation`, locked replay counter, and active mobile envelopes are pending follow-up slices. No pairing keypair, QR secret, plaintext envelope, or business/PII payload persists.

Pending future bodies (not implemented):

```json
{"version":2,"installation_id":"uuid","counter":1,"nonce":"base64url-24-bytes","ciphertext":"base64url"}
```

Canonical envelope AAD length-prefixed: `openpaycongo/mobile-envelope/v2`, installation routing id, uppercase HTTP method, canonical path, decimal counter/request id. XChaCha20-Poly1305 authenticates data/AAD before Laravel sees plaintext. No per-message signature. Outer API routing/envelope only; business/PII ciphertext until authenticated decryption.

## Persistence and interoperability

Intent lifetime 30 seconds to five minutes. Transaction locks intent, validates QR-secret envelope, derives keys, stores encrypted directional keys/SAS, emits encrypted response, clears private material/QR-secret digest. Failed attempts never reveal cause. Every pairing response: `Cache-Control: private, no-store`.

Cross-platform fixtures must have deterministic test-only server/client KX keypairs, QR secret, intent id, nonce/ciphertext, response nonce/ciphertext, exact AAD bytes, expected directional plaintexts. Android/PHP contract tests prove decrypt plus reject changed version, installation id, method, path, counter, nonce, ciphertext, AAD.
