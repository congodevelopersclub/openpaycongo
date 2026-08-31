# Pairing v2 interoperability plan

`pairing-v2.fixture.json` is public deterministic test data. It contains test-only private seeds and a test-only QR secret. Production code must generate all seeds, secrets, and nonces with its CSPRNG and must never log or ship fixture values.

## Required tests

1. PHP uses ext-sodium `sodium_crypto_kx_seed_keypair`, `sodium_crypto_kx_client_session_keys`, and `sodium_crypto_kx_server_session_keys`. It must prove client send equals server receive and client receive equals server send for fixture keys.
2. Flutter uses the maintained Sodium binding `crypto_kx_client_session_keys` and `crypto_kx_server_session_keys` equivalents. It must prove the same four directional-key outputs without a hand-written X25519 or KDF.
3. Both runtimes construct completion AAD as length-prefixed bytes: protocol label, raw 16-byte intent id, raw 32-byte client public key. Both decrypt fixture completion ciphertext to exactly the 32-byte QR secret; change any AAD field, nonce, ciphertext, or key -> decrypt failure.
4. Both runtimes construct response AAD as length-prefixed bytes: response protocol label, raw 16-byte intent id. Both decrypt fixture response ciphertext to exactly the JSON shown; change any AAD field, nonce, ciphertext, or key -> decrypt failure.
5. Both runtimes validate and verify every QR field: strict JSON shape, canonical endpoint, expiry, suite, fingerprint, Ed25519 signature transcript, `pairing_secret`, and trust mode. Mutate each signed field once; every mutation must fail signature verification.
6. Server feature test issues fresh QR data, completes once with fresh client material, verifies encrypted response and `private, no-store`, then retries exact saved bytes and proves same encrypted `201` response without second pairing. Malformed, expired, unknown, altered, or non-identical consumed attempts produce indistinguishable unavailable response. Do not assert secret values in logs/errors.
7. Mobile BLoC test keeps QR, secret, private key, directional keys, nonce, ciphertext, and SAS out of state `toString`, analytics, notifications, screenshots, backups, and crash reporting. Android secure storage holds pending pairing material; it is unusable before confirmation.

## Follow-up boundary

Current server slice ends at `pending_confirmation`. Confirmation/activation, replay semantics, transfer to `SourceInstallation`, counter-bound active mobile envelopes, rotation, and recovery need their own feature tests before being described as implemented.
