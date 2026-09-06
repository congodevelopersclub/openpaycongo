# Canonical cross-client contract

Status: executable contract inventory for the Laravel server and Flutter Android
consumer. This document describes only the surfaces represented by checked-in
schemas, fixtures, OpenAPI operations, and tests. It does not claim that every
planned endpoint is implemented.

## Sources of truth

`docs/openapi.yaml` is the HTTP shape: paths, methods, authentication,
request/response schemas, status codes, scopes, and cache behavior. JSON Schema
files in this directory are the reusable payload contracts. The deterministic
fixtures are synthetic conformance inputs; they are not credentials, secrets,
customer records, or production examples.

The current implemented Laravel surfaces are:

| Surface | Canonical operations | Consumer/evidence |
| --- | --- | --- |
| Developer Applications | `POST /oauth/token`, `GET /services/identity` | `server/routes/api.php`, `server/tests/Feature/DeveloperApplicationCredentialsTest.php` |
| Mobile deposits | `POST /mobile/deposits` | `server/routes/api.php`, `server/tests/Feature/MobileDepositIngressTest.php` |
| Mobile envelope | `POST /mobile/envelopes` | `docs/mobile-envelope-v1.md`, `server/tests/Feature/MobileEnvelopeIngressTest.php` |
| Pairing | `/v1/pairing/*` | `docs/pairing-v2-test-plan.md`, `server/tests/Feature/IssuePairingIntentHttpTest.php` |
| Mobile consumer boundary | pairing and sync seams only; no live sync transport | `android-client/README.md`, `android-client/test/` |

The `/v1/sync/*` operations remain a published planned contract until the
Laravel routes and Flutter transport exist. They must not be presented as a
delivered runtime feature.

## Shared rules

- Errors use `application/problem+json` and include a non-sensitive
  `request_id` where the operation references the `Problem` schema. OAuth token
  errors use the OAuth error shape.
- A successful repeated mobile deposit is an idempotent `200` replay. A changed
  transfer under an existing provider reference is a `409` conflict. Pairing
  and encrypted-envelope retries use their operation-specific opaque response.
- Pagination is cursor-based wherever a pull/read operation declares a cursor;
  cursors are opaque and must not be parsed or fabricated by clients.
- Scopes are least-privilege OAuth grants. `customers:pii:read` is reserved and
  is never granted by the ordinary Developer Application flow.
- Organization and installation identity are derived from authenticated
  credentials. They are prohibited from trusted mobile deposit bodies.
- Optional PII fields in `MobileDepositRequest` are encrypted server-side and
  are never returned, logged, placed in telemetry, or copied into fixtures
  except as synthetic contract data.
- No encrypted field, client secret, bearer token, pairing key, lookup token,
  or raw SMS value is part of a public response or example.

## Compatibility and deprecation

Additive changes require an explicit schema-compatible test. Changes to a
required field, enum, authentication rule, status code, idempotency key,
cursor encoding, money/timestamp encoding, or PII boundary are breaking or
security changes until maintainers approve and publish a migration path.

Every compatibility change must update the OpenAPI document, the relevant
JSON Schema and synthetic positive/negative fixture, and the Laravel/Flutter
consumer test. The [versioning policy](versioning-policy.md) records the
approval boundary, support-window, and deprecation decisions; this contract
does not invent an end-of-life date or release authority.

## Verification

Run the canonical Docker contract gate from the repository root:

```bash
docker build --target test -f docs/Dockerfile .
docker build --target test -f server/Dockerfile .
docker build --target test -f android-client/Dockerfile.ci android-client
```

The first command validates the OpenAPI document, JSON Schemas, fixtures,
route inventory, and documentation boundary. The Laravel and Flutter commands
run their consumer suites. A contract is not complete when only the YAML
parser passes.
