# Congo OpenPay Server

`server/` is the canonical Congo OpenPay backend. It is a Laravel 13
application: application behavior belongs in Laravel routes, Form Requests,
Actions, Eloquent models, events, queued listeners, API Resources, migrations,
and policies as the implementation grows. Livewire or Filament components may
coordinate presentation, but must not own business rules.

Production targets PostgreSQL and Laravel's database queue. SQLite and
MySQL/MariaDB remain supported for development and testing. Do not introduce a
second backend, a generic repository layer, MongoDB, or a separate admin SPA.

## Customer and provider PII

Customer `name`, `address`, `phone`, and `email`, plus deposit
`provider_reference`, `sender_identifier`, `receiver_identifier`, and
`reversal_detail`, are PII. They use Laravel's built-in `encrypted` Eloquent
cast, `TEXT`-or-larger storage, and model `$hidden` redaction. Do not put these
values in events, queues, logs, telemetry, exceptions, fixtures, or API output.

Money and operational provenance stay queryable: amounts, currency, kind,
timestamps, organization/customer/install identifiers, reversal linkage, and
deduplication metadata. Existing lookup/idempotency digests remain
non-reversible operational metadata; no custom encryption or hash lookup is
introduced for PII.

For key rotation, deploy a new `APP_KEY` while retaining retired keys in
`APP_PREVIOUS_KEYS`. Laravel decrypts existing values with those prior keys.
Through an authorized controlled maintenance path, mutable Customer PII can be
saved to re-encrypt it with the current key. Deposits are immutable financial
records: never rewrite their PII to rotate encryption. Keep prior keys for
their decryptability until an explicitly designed compliant migration and
re-encryption approach exists. This does not authorize PII retention changes,
administrative reveal, or API PII exposure.

## Quality checks

Laravel Boost is installed as a development dependency. Its generated agent
configuration is local and regenerable; from this directory, run:

```bash
composer install
php artisan boost:install
```

For non-interactive CI or a container, run the explicit setup below. It enables
Boost guidelines, skills, and MCP configuration without writing credentials:

```bash
php artisan boost:install --no-interaction --guidelines --skills --mcp
```

Run the quality gates locally with Composer:

```bash
composer run lint
composer run analyse
composer run quality
composer test
```

The canonical reproducible check runs all quality gates and Laravel tests in
Docker from the repository root:

```bash
docker build --target test -f server/Dockerfile .
```

Pint is check-only in CI. Apply its Laravel formatting locally with
`vendor/bin/pint`, review the resulting diff, and then re-run the Docker check.
Composer resolves the lockfile against PHP 8.3.0, the declared minimum; the
Docker test target also performs a PHP 8.3 Composer install dry run before
running the normal quality gates.
