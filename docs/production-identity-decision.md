# Production identity and token-lifecycle decision packet

## Status

This packet prepares issue #9; it does not establish production authentication.
The production issuer, discovery method, token format, claim mapping, client
registration, rotation, revocation, outage, recovery, retention, and approval
authority are **not yet approved**. It does not select any of those values.

## Repository evidence

- The public OpenAPI currently uses `identity.example.invalid` as placeholder
  OAuth endpoints. That is contract scaffolding, not an approved issuer.
- The public contract identifies three OAuth principal categories:
  administrator, mobile, and merchant. It also defines a separate opaque pairing
  status bearer that is explicitly not an administrator OAuth token.
- Existing architecture documentation requires tenant, replica where enrolled,
  scopes, and wallet membership to derive from verified authority; canonical
  event payloads exclude tenant identity.
- Current repository status is prototype-only: authentication, secure secret
  storage, deployable server images, and production releases are not complete.
- The pairing domain proves a bounded local enrollment protocol, but does not
  independently authenticate a compromised hosting edge, administrator UI, or
  OAuth session.

## Decisions required from maintainers

Maintainers must approve the issuer and discovery rules; JWT versus opaque-token
validation; audiences; client registrations; signing-key rotation; token expiry,
not-before, clock-skew, revocation, logout, cache invalidation, and issuer-outage
behavior; any trusted reverse-proxy header; break-glass and recovery authority;
and audit-event retention and privacy boundaries.

The decision must also name accountable owners and a safe rollback path when
issuer discovery or keys are unavailable. This packet does not select an issuer,
audience, claim value, lifetime, trusted proxy, or recovery authority.

## Claim-matrix decision gate

Before production authentication is implemented, maintainers need an approved,
versioned matrix for administrator, merchant, mobile-install, and service
principals. For each principal it must state verified issuer, audience, subject,
tenant, wallet membership, install/replica binding where applicable, scopes,
client type, and the source of each authorization fact.

The matrix must explicitly prohibit tenant or wallet authority from request JSON,
query parameters, browser state, local configuration, or an unverified header.
It must separately enumerate which, if any, endpoint may accept an identity header
after trusted reverse-proxy verification; analytics and mobile APIs must not
silently inherit a web-administration header.

## Token-lifecycle decision gate

The approved policy must define issuance, validation, clock handling, key
discovery caching, rotation overlap, revocation propagation, scope reduction,
logout, issuer unavailability, and rollback. It must state how malformed,
expired, not-yet-valid, revoked, wrong issuer, wrong audience, wrong scope, and
tenant-confused tokens are handled without leaking secrets or verified claims.

No duration, key algorithm, cache period, or break-glass path is approved by this
document.

## Fixture and adapter gate

After approval, a versioned public fixture suite must cover valid tokens plus
missing scope, wrong audience, wrong issuer, expired/not-yet-valid token, revoked
token, rotated key, tenant confusion, and clock skew. Laravel must consume the
fixtures and emit the documented public problem responses. Development
static-token adapters must fail startup in production mode.

Browser clients must never receive a backend bearer or signing material. Logs,
errors, telemetry, and CI artifacts must redact secrets, tokens, and verified
claims according to the approved policy.
