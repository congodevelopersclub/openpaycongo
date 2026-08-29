# API versioning, compatibility, and deprecation policy

## Status

This is a policy foundation for issue #68. It records the version identity already present in checked-in contracts and the compatibility decisions still required from maintainers. It does not declare any runtime, datastore, mobile artifact, or API version supported for production.

## Observable version identity

The canonical OpenAPI contract requires `/version` to expose `build`, `contract_version`, `implementation`, `adapter`, and `migration_revision`. `/readyz` also exposes `contract_version`, `migration_revision`, implementation, and adapter. Recovery design requires versioned export manifests with migration checksums and projection revision. These fields are diagnostic identity, not proof that two implementations are compatible.

The repository also contains versioned OpenAPI, JSON schemas, canonical event fixtures, pairing vectors, analytics vectors, and a black-box harness foundation. A target that declares an unavailable capability is explicitly skipped and does not count as parity.

## Change classification

The following categories are proposed vocabulary for maintainer approval; they are not yet approved release rules.

| Change class | Compatibility question that must be answered before merge or release |
| --- | --- |
| Additive | Can an older consumer safely ignore the new field, endpoint, enum value, or fixture case, and does the schema permit that behavior? |
| Breaking | Does the change alter or remove a published request, response, error, authentication requirement, money/timestamp encoding, cursor, digest, or recovery invariant? |
| Behavioral | Does the published shape stay the same while authorization, idempotency, ordering, cache, retry, readiness, or recovery behavior changes? |
| Security | Does the change narrow authorization, rotate trust material, revoke an identity, alter data exposure, or require an emergency compatibility exception? |
| Fixture/schema | Does a vector, schema, migration revision, or conformance case change its canonical bytes or expected invariant? |

Until maintainers approve classification consequences, a potentially breaking change must be treated as a release blocker rather than silently labelled additive.

## Compatibility and fixture gates

Before a compatibility claim, the relevant Docker contract suite must prove both of the following:

1. A backward-compatibility case showing the approved older input/output/fixture behavior still succeeds where support is claimed.
2. An intentional-breaking-change case showing the newer/unknown version, revision, field, or fixture is rejected before a write or unsafe interpretation.

Laravel contract tests must report datastore, declared capabilities, case identifier, request, and failed invariant. The current analytics and operational fixtures are foundation evidence only; they do not establish a supported database matrix.

Migration and export compatibility must preserve canonical encodings, ordered event count/digests, and recovery truth. A newer or unknown schema/migration revision must not be accepted for writes until the approved negotiation behavior exists.

## Upgrade and deprecation workflow

Maintainers must approve an explicit upgrade order for client, server, datastore, and mobile artifact combinations before asserting a supported path. Each future deprecation record must identify the affected contract/fixture/schema/runtime/artifact version, migration or rollback boundary, compatibility evidence, user communication path, and removal authority.

No support-window duration, end-of-life notice period, emergency bypass authority, or deprecation owner is selected by this document.

## Pending maintainer authority

The following are **not yet approved**:

- Version identifier syntax and which change classes increment contract, fixture, schema, runtime, mobile, and artifact versions.
- Compatibility promise, support-window duration, upgrade order, and end-of-life notice process.
- Who may approve breaking, behavioral, security, fixture, migration, and emergency compatibility changes.
- The public deprecation communication channel and release/rollback authority.
- The exact backward-compatibility and intentional-breaking-change fixtures required in CI for each supported matrix entry.

Until these decisions are approved, contributors must publish observable identity fields and synthetic fixture evidence without claiming support or compatibility beyond the tested case.
