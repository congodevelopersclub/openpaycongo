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

```bash
docker build --target test -f docs/Dockerfile .
docker build --target test -f server/Dockerfile .
docker build --target analyze -f android-client/Dockerfile.ci android-client
docker build --target test -f android-client/Dockerfile.ci android-client
docker build --target artifact --output type=local,dest=android-client/build/ci \
  -f android-client/Dockerfile.ci android-client
```

The Laravel server build runs Pint in check mode, Laravel-aware static analysis,
and the Laravel test suite in that order. For an individual local check from
within `server/`, run `composer run lint`, `composer run analyse`, or `composer
run quality`.

The Flutter APK is debug-signed CI output, not a distributable release. A
production image, PostgreSQL Compose stack, queue worker, scheduler, backups,
and restore procedure are tracked separately before any deployment claim.

## Security and operational notes

Raw SMS is deliberately excluded from canonical public event payloads. Never
commit credentials, production SMS, wallet databases, or generated secrets.
See [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/](docs/) for current design
boundaries and fixture evidence.
