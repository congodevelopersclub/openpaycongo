# ADR 008: Laravel identity boundaries

## Status

Accepted

## Decision

- Administrators authenticate only through Fortify `web` sessions, after confirmed TOTP or passkey. They never authenticate as API bearer identities. This extends [ADR 007: first-run administrator setup](adr-007-first-run-admin-setup.md).
- Developer services use confidential Passport OAuth2 client-credentials. This self-hosted Laravel server validates resources locally; there is no OIDC discovery, external issuer, or refresh token.
- Mobile installations use Sanctum tokens under the distinct `mobile` guard and mobile abilities. Only pairing issue #17 may issue an installation token; this ADR does not implement pairing or issuance.
- Authorization resolves organization, application, and installation from persisted token or client ownership. Request identifiers and claims never select ownership.
- Reverse-proxy identity headers are never identity authority. The canonical base URL is static configuration.
- Service access tokens expire after 15 minutes. Mobile installation tokens expire after 24 hours. Accepted clock skew is at most 60 seconds. Expiry, revocation, rotation, and recovery fail closed.
- Administrator-authorized session policy controls client registration, rotation, revocation, and recovery. Audit records contain safe metadata only; no break-glass or shared credentials exist. A client secret is shown exactly once and never reaches logs, queues, telemetry, or errors.
- Service scopes are `payment-requests:read`, `payment-requests:write`, `deposits:read`, `wallets:read`, `customers:read`, and reserved `customers:pii:read`. Mobile scopes are `mobile:deposits:write`, `mobile:sync:read`, `mobile:sync:write`, and `mobile:telemetry:write`. Administration remains session-and-policy only.
- Mobile authenticated requests are limited to 60 per minute per persisted installation. Authentication and authorization failures use stable, non-enumerating responses.

## Consequences

This slice configures supported Passport and Sanctum guards, expiry, scopes, persisted mobile ownership, and a protected identity seam. It intentionally excludes #17 pairing/token issuance, administrator client-management UI #45, credential rotation/recovery workflows, and all request-selected tenant ownership.
