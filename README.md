# Congo OpenPay

> **Prototype status — not production-ready.** Congo OpenPay Server is the one
> canonical backend implementation. It is a native Laravel application in
> `server/`. Do not process real payments, SMS, credentials, or enrollment data.

## Repository map

- `server/` — Congo OpenPay Server, the canonical Laravel backend.
- `android-client/` — Flutter mobile prototype.
- `docs/` — public contracts, runtime-neutral fixtures, ADRs, and design notes.

The public contracts describe planned behavior; they are not proof that every
endpoint is implemented. Runtime-neutral fixtures remain in `docs/` so future
Laravel tests can consume their canonical bytes without a competing backend.

## Reproducible Docker checks

Use the repository-owned tier runner for ordinary work:

```bash
bash scripts/ci/fast-feedback.sh focused contracts docs/public-contract.test.mjs
bash scripts/ci/fast-feedback.sh local laravel
bash scripts/ci/fast-feedback.sh pr flutter
```

Run `bash scripts/ci/fast-feedback.sh` for the full tier and component catalog.
Every command runs the relevant runtime in Docker. The pull-request tier is
unconditional in CI; do not path-skip it. The direct Docker commands below are
the component-level building blocks used by the runner.

```bash
docker build --target test -f docs/Dockerfile .
docker build --target test -f server/Dockerfile .
docker build --target analyze -f android-client/Dockerfile.ci android-client
docker build --target test -f android-client/Dockerfile.ci android-client
docker build --target artifact --output type=local,dest=android-client/build/ci \
  -f android-client/Dockerfile.ci android-client
```

The Laravel server build runs Pint in check mode, Laravel-aware static analysis,
and the Laravel test suite in that order. Use the Docker-only tier runner for
individual checks; do not treat host Composer output as verification.

The Flutter APK is debug-signed CI output, not a distributable release. The
Laravel runtime and PostgreSQL Compose instructions are in
[docs/operations.md](docs/operations.md). They do not make the unfinished
application protocol safe for real payment, SMS, credential, or enrollment
data.

## Security and operational notes

Raw SMS is deliberately excluded from canonical public event payloads. Never
commit credentials, production SMS, wallet databases, or generated secrets.
See [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/](docs/) for current design
boundaries and fixture evidence.
