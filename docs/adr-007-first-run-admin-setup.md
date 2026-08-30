# ADR 007: First-run administrator setup and passkey boundary

Status: accepted for issue #26 on 2026-08-30.

## Decision

An unclaimed installation exposes one browser setup entry point. It creates the
first organization and financial operator exactly once, then permanently closes
that entry point. The administrator must enroll and confirm Fortify TOTP before
an operational route can be used. Recovery codes remain a recovery mechanism,
not a way to avoid enrollment.

An installation which already has any users is treated as legacy and setup is
closed by migration before a request can reach it. Public first-run setup is
never a remediation mechanism for an existing installation. After all
migrations have run, a locally authenticated release operator may run the
explicit `openpay:provision-legacy-operator <numeric-user-id> --force` command.
It locks the closed setup state, refuses an existing operator or ambiguous
organization ownership, creates or uses the sole organization, and records a
non-secret audit event. The provisioned user must sign in and complete Fortify
TOTP enrollment plus recovery-code acknowledgement before operations; the
command does not establish an MFA session.

## Browser verification boundary

`bash scripts/ci/run-initial-setup-browser.sh` runs the first-install form, setup
replay denial, pre-TOTP operations denial, and passkey-enrollment hiding against
an isolated Docker Laravel stack. It does not exercise a WebAuthn ceremony,
reauthentication, or credential persistence, and records no physical
authenticator, credential private key, biometric, or challenge. The maintained
package's server routes, trust configuration, ownership, reauthentication,
persistence model, and MFA-state transitions are covered by Laravel feature
tests; a physical authenticator remains an operator acceptance exercise outside
automated CI.

Passkeys supplement, rather than replace, the password and TOTP flow. The
application uses Laravel Fortify's maintained `laravel/passkeys` integration;
it does not parse WebAuthn ceremonies or create cryptographic material itself.
Passkey login is discoverable and publicly available after setup, while the
password login and recovery-code fallback remain available.

## Relying-party contract

This repository intentionally has no shared production hostname. A deployment
must therefore set these exact values before enabling passkeys:

- `OPENPAY_APP_URL` is the one canonical public HTTPS origin.
- `OPENPAY_PASSKEY_RP_ID` is its hostname, without scheme or port.
- `OPENPAY_PASSKEY_ALLOWED_ORIGINS` is an explicit JSON array containing only
  that canonical HTTPS origin.

Production rejects missing, non-HTTPS, wildcard, mismatched, or additional
origins. It never derives a trusted WebAuthn origin from request headers. Local
testing may use `https://localhost` as its exact origin and `localhost` as its
RP ID.

## Enrollment and data boundary

Passkey enrollment and deletion require an authenticated, recently
re-authenticated administrator and retain the package's credential ownership
and multiple-credential model. The maintained package stores only public
credential material and its opaque stable user-handle association. The
application never stores authenticator private keys, biometrics, challenges,
assertions, recovery codes in plaintext, or browser credential payloads in
logs.

## Consequences

The setup and panel boundaries remain fail closed until both a confirmed TOTP
factor and a verified MFA session exist. A deployment that has not selected its
canonical origin can still use password/TOTP setup, but cannot advertise or
complete passkey enrollment or public passkey login.
