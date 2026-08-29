# Congo OpenPay Server

`server/` is the canonical Congo OpenPay backend. It is a Laravel 13
application: application behavior belongs in Laravel routes, Form Requests,
Actions, Eloquent models, events, queued listeners, API Resources, migrations,
and policies as the implementation grows. Livewire or Filament components may
coordinate presentation, but must not own business rules.

Production targets PostgreSQL and Laravel's database queue. SQLite and
MySQL/MariaDB remain supported for development and testing. Do not introduce a
second backend, a generic repository layer, MongoDB, or a separate admin SPA.

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
