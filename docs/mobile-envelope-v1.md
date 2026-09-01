# Mobile envelope v1

`POST /mobile/envelopes` is the server-side encrypted transport for a paired installation. It has no bearer credential. The caller is authenticated by possession of the client-to-server directional key created during pairing.

This document is normative with [ADR 004](adr-004-secure-device-enrollment.md). It intentionally specifies one operation, `deposit`; network scheduling and an Android transport adapter are separate work.

## Security boundary

HTTPS still protects routing and availability. The envelope keeps payment and customer data confidential from TLS-terminating proxies and authenticates the paired phone to the server. The visible request metadata is endpoint, timing, size, installation UUID, counter, nonce, and ciphertext.

The protocol uses the maintained libsodium XChaCha20-Poly1305-IETF implementation in PHP ext-sodium and Android. It does not use raw X25519, a custom KDF, Laravel `Crypt`, OpenSSL wire crypto, a custom signature, or a ratchet. Pairing established independent directional 32-byte keys:

- Client request encryption uses `client_send_key == server_receive_key`.
- Server response encryption uses `server_send_key == client_receive_key`.

AEAD authenticates the holder of each directional key; a separate signature would not add sender authentication. Key rotation occurs only by the explicit pairing/revocation/rotation lifecycle, not per message.

## Request

The request body is JSON with exactly these fields; unknown fields, JSON arrays, non-canonical encodings, and malformed values are rejected:

```json
{
  "version": 1,
  "installation_id": "canonical-lowercase-uuid",
  "counter": "1",
  "nonce": "base64url-24-bytes",
  "ciphertext": "base64url"
}
```

`counter` is a positive, canonical decimal string in the inclusive range `1` through `9223372036854775807` (`PHP_INT_MAX`). The server locks the installation and accepts a counter only when it is greater than the durable stored counter. It persists the accepted counter in the same transaction as the deposit result. The client persists its next counter before sending. A retry after an unknown response therefore creates a new envelope with the next counter; deposit idempotency returns an encrypted `replayed` outcome rather than creating a second deposit. A client at the maximum value must fail closed and require a new pairing lifecycle; it must never wrap or reuse a counter.

The request nonce is exactly 24 random bytes. `ciphertext` is canonical unpadded base64url, decodes to at least the XChaCha20-Poly1305 authentication tag, and is limited to 12 KiB. The request AAD is the direct concatenation of:

1. unsigned 16-bit big-endian byte length, then UTF-8 `openpaycongo/mobile/request-envelope/v1`;
2. raw 16-byte UUID from `installation_id`;
3. unsigned 64-bit big-endian `counter`.

Request plaintext is UTF-8 JSON with exactly:

```json
{
  "version": 1,
  "operation": "deposit",
  "payload": {
    "customer_lookup_identifier": "customer-001",
    "provider_reference": "provider-reference",
    "amount_minor": 12500,
    "currency": "CDF",
    "provider_occurred_at": "2026-09-01T01:00:00Z"
  }
}
```

`payload` uses the same Laravel validation and immutable-deposit rules as `POST /mobile/deposits`: CDF-only positive integer money, strict portable timestamp, bounded control-character-free identifiers, and optional bounded customer PII. Tenant and source installation are always derived from the paired installation, never from plaintext input. Plaintext is not logged, queued, returned, or serialized; it is cleared from the PHP variable after JSON parsing.

## Response

For an authenticated, valid request, the server returns `201`, `200`, or `409`, always with `Cache-Control: no-store, private`, and exactly:

```json
{
  "version": 1,
  "nonce": "base64url-24-bytes",
  "ciphertext": "base64url"
}
```

The server generates a fresh 24-byte nonce. Response plaintext is exactly one of:

```json
{"outcome":"recorded"}
```

```json
{"outcome":"replayed"}
```

```json
{"outcome":"conflict"}
```

The response AAD is the direct concatenation of:

1. unsigned 16-bit big-endian byte length, then UTF-8 `openpaycongo/mobile/response-envelope/v1`;
2. raw 16-byte UUID from the request;
3. unsigned 64-bit big-endian request `counter`;
4. unsigned 16-bit big-endian HTTP response status.

The status is authenticated as part of the response. `recorded` is `201`, an idempotent same-transfer result is `200`, and a provider reference paired with changed transfer data is `409`.

## Failure behavior

Malformed, unknown, stale, retargeted, oversized, unauthenticated, wrong-operation, or otherwise invalid envelopes all return the identical `404` body:

```json
{"code":"mobile_envelope_unavailable"}
```

They also use `Cache-Control: no-store, private`. Such failures do not advance the counter and do not create a deposit or ledger entry. The caller must not use failure distinctions as a pairing-state oracle.

## Deterministic interoperability vector

This test-only vector lets every native implementation prove byte-for-byte request compatibility with Laravel. It contains no production key, customer data, phone number, or payment reference. XChaCha20-Poly1305 encryption is deterministic when the key, nonce, plaintext, and AAD are fixed.

| Input | Value |
| --- | --- |
| Client-to-server key (hex) | `000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f` |
| Installation UUID | `123e4567-e89b-12d3-a456-426614174000` |
| Counter | `"1"` |
| Nonce (base64url) | `AAECAwQFBgcICQoLDA0ODxAREhMUFRYX` |

The AAD is exactly the request AAD specified above. Encrypt this exact UTF-8 plaintext, without a trailing NUL byte:

```json
{"version":1,"operation":"deposit","payload":{"customer_lookup_identifier":"fixture-customer","provider_reference":"fixture-reference","amount_minor":1250,"currency":"CDF","provider_occurred_at":"2026-01-02T03:04:05Z"}}
```

The unpadded base64url ciphertext must be:

```text
5eB5GuKh5MFdZhz_53DHmC41SdGUuXPJRThb003ChjAqJJrGMQZwCLr0ynv1WnEBBMmWNioRiUZr9PxW-pcbndZFkcdh_w3gXn0c4z0McdYscnm30HBO7Tn9WAWTPVE8HGsDJXN1ApSXaFuyQWQzP1Ud9dmAMgMQvAM7AhXsv4xgwAwurpVn-OP1WCZoxaLunyoG8iiuHjOTgiFY6pK9kkXf72uOJ-G20z96b3bR93aiw4yaIdIwVGymAtxoWQ6zjkOvj88rL9ReM68_FPnoO4lJ7VyX5R_lOtMcRHpG-t6JVCBGxgH39qw0wQ
```

Laravel submits this vector unchanged through `/mobile/envelopes` and decrypts the response. Response ciphertext deliberately has no fixed vector because the server generates a fresh nonce.

## Compatibility and limits

This endpoint is v1-only and currently accepts only deposits. It deliberately does not turn the legacy bearer-protected `POST /mobile/deposits` endpoint into an encrypted endpoint; that compatibility route remains separately protected.

Android #211 implements local native sealing only: a foreground, unlocked bridge accepts a bounded deposit payload from Dart, reserves a Keystore-encrypted no-backup counter, reads the stored send key natively, and returns only version, installation id, counter, nonce, and ciphertext. It does not implement HTTP delivery, response decryption, acknowledgement, revocation, rotation, or recovery. The deposit payload necessarily originates in Dart before this boundary and must not be logged, persisted, or added to BLoC state.

Pairing v2 owns the directional-key lifecycle in Android native code: it derives the keys with libsodium, holds them only in a process-scoped exchange while authenticating the completion response, then saves them in the Keystore-backed vault. Flutter receives only public completion request fields and the SAS. The native envelope path neither returns a directional key nor uses a bearer credential.
