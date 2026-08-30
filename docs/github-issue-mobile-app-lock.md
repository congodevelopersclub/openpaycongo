# Mobile app-lock verification boundary

Issue #12 uses a versioned Android-Keystore-encrypted Argon2id verifier record:
64 MiB memory, three iterations, parallelism one, a random 16-byte salt, and
a 32-byte verifier. The fixed v1 format rejects a record whose version,
algorithm, or cost fields differ from the parameters the implementation
derives. The PIN is never stored. Failed PIN attempts persist a bounded count
and a cooldown capped at fifteen minutes. Missing or invalidated Keystore
material, malformed verifier records, and secure-storage failures enter
`recovery_required`; no automatic wipe or unlock bypass exists.

The Flutter BLoC and JVM tests prove the public transition rules, input format,
stale lifecycle generations, cooldown cancellation, and verifier-format policy.
They do **not** prove physical-device hardware-backed Keystore behavior, key
invalidation, biometric prompt semantics, screenshot behavior on every OEM, or
resistance to device coercion. Those require instrumented physical-device
evidence before a production release claim.
