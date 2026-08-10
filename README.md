# OpenPay Congo

> **Prototype status — not production-ready.** The checked-in Flutter client and Go wallet server are incomplete experiments. They do not yet implement the canonical sync contract, authentication, encryption-at-rest, secure secret storage, release signing, or a deployable server image. Do not process real payments or real SMS data with this repository.

OpenPay Congo is being specified as a mobile local-first payment inbox and outbox. The mobile device records payment events while offline; a backend later replicates an immutable ledger and derives balances. The public interoperability contract is additive planning material, not evidence that this behavior is implemented.

## Repository map

- `android-client/` — Flutter prototype for Android; it currently parses a narrow Orange SMS format and has incomplete flows.
- `wallet-plugin-go/` — Go/SQLite wallet-server prototype; its current routes are legacy and are not the canonical v1 contract.
- `docs/` — canonical contract, PRDs, ADRs, reliability notes, and the Docker-only contract validator.
- `.github/workflows/ci.yml` — current baseline CI; it needs the planned release and supply-chain hardening described in the documentation.

## Current prerequisites

- Git.
- Docker Desktop for all reproducible CI checks below.
- Flutter **3.44.9** with Dart **3.12.2** for the Android CI image.
- Go **1.26.5** for the Go prototype (`go.mod` requests that toolchain).
- No Docker deployment image release process exists yet.

## Optional host-only exploration

The commands below exercise only the present prototypes; they do not establish CI or production readiness.

```bash
# Flutter prototype
cd android-client
flutter pub get
flutter analyze
flutter test
flutter run

# Go prototype (creates/uses a local wallet.db in this directory)
cd ../wallet-plugin-go
go test ./...
go run ./cmd/server

# Canonical public-contract validation — Docker only
cd ..
docker build --target test -f docs/Dockerfile .
```

The contract build uses no bind mounts or named volumes; its dependencies are image-internal. The Android prototype requests SMS/biometric capabilities; use only test messages and a test device.

## Reproducible Docker CI commands

Run these commands from the repository root for reproducible CI evidence:

```bash
# Canonical public contract and delivery-policy validation
docker build --target test -f docs/Dockerfile .

# Go public tests, vet, race detector, and runtime image
docker build --target test -f wallet-plugin-go/Dockerfile wallet-plugin-go
docker build --target runtime -t openpaycongo-wallet:local -f wallet-plugin-go/Dockerfile wallet-plugin-go

# Flutter analysis, tests, and a non-production debug APK
docker build --target analyze -f android-client/Dockerfile.ci android-client
docker build --target test -f android-client/Dockerfile.ci android-client
docker build --target artifact --output type=local,dest=android-client/build/ci \
  -f android-client/Dockerfile.ci android-client

# Admin UI health and browser journey against its Compose fake upstream
docker compose -f admin-ui/compose.test.yaml up --build --abort-on-container-exit --exit-code-from browser
docker compose -f admin-ui/compose.test.yaml down --volumes --remove-orphans
```

`android-client/build/ci/app-debug.apk` is debug-signed CI output, not a distributable release. The admin Compose journey uses a checked-in fake upstream and is browser/health evidence for the UI boundary, not live backend integration evidence. The Dockerfiles make prototype checks reproducible; they do not add deployment configuration, database configurability, signing, SBOMs, provenance, or a production image release process.

## Supported today vs planned

| Area | Current state | Planned contract |
| --- | --- | --- |
| Mobile inbox | Prototype SMS parsing and local SQLite only | Offline inbox/outbox, explicit delivery state, recovery UX |
| Backend ledger | Prototype Go/SQLite endpoints | Authenticated immutable replicated ledger and derived balance |
| Sync | Not implemented | `POST /v1/sync/push`, `GET /v1/sync/pull`, `POST /v1/sync/ack` |
| Merchant integration | Not implemented | One canonical event push with idempotency semantics |
| Releases | No signed Android or container release | Signed/mobile release, SBOM, provenance, scan, rollback evidence |

## Security and operational notes

The older French material records product intent, not implemented controls. Treat API keys/HMAC, encryption, parser sharing, and retry behavior there as **unimplemented** until a release says otherwise. Raw SMS is deliberately excluded from the canonical public event payload. Never commit credentials, production SMS, or wallet databases.

The canonical API specifies OAuth-style scopes, RFC 9457 problem responses, idempotency, and storage parity. Implementation, threat modeling, key management, retention, replay defense, and operational approval remain required.

## Documentation

- [Mobile PRD](docs/prd-mobile.md)
- [Backend PRD](docs/prd-backend.md)
- [Architecture](docs/architecture.md), [reliability and recovery](docs/reliability.md), and [interoperability/storage parity](docs/interoperability.md)
- [Canonical OpenAPI 3.1 contract](docs/openapi.yaml), [event schema](docs/ledger-event.schema.json), and fixtures
- [ADR 001 — local-first authority](docs/adr-001-local-first-authority.md), [ADR 002 — replicated sync](docs/adr-002-replicated-sync.md), [ADR 003 — parser proposal trust](docs/adr-003-parser-proposal-trust.md)

## Screenshots

Android truth note: the manifest declares SMS receipt, but the current `SmsParser` initializer is unwired; the app does not currently request or listen for SMS. Biometric authentication is an authentication prompt, not an Android runtime permission. Any future SMS capability must assess API/distribution/default-handler eligibility, request only in context, handle deny/permanent-deny/settings/unsupported states, and retain fully tested manual/merchant fallback.

There are no real-app screenshots in this repository. Screenshots will be added only after capture from the actual app running a documented, reproducible test journey; no mockups or fabricated product evidence will be substituted.
