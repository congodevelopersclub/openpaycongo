# Self-hosted Laravel runtime

`compose.yaml` runs one small PostgreSQL-backed Laravel installation. The
application image is built in stages, has no development dependencies, runs as
the unprivileged `openpay` user, and writes only to `storage/` and
`bootstrap/cache`. Its Docker health check requests `/healthz`.

This is an operational deployment baseline, not a declaration that the
unfinished payment, identity, privacy, retention, or recovery protocol is safe
for real customer data. Keep the repository's prototype and threat-model
boundaries in force.

## Start the stack

Use Docker Engine with Compose v2. Do not put production values in the
repository, an image, issue, pull request, shell history, or CI artifact. Store
them in the deployment secret manager or protected host environment instead.

Generate a distinct Laravel key once for each environment:

```bash
docker run --rm php:8.3-cli-alpine php -r 'echo "base64:".base64_encode(random_bytes(32)).PHP_EOL;'
```

Set that output and a strong PostgreSQL password in the protected deployment
environment. Compose binds the app only to loopback by default. Set
`OPENPAY_HTTP_BIND_ADDRESS` only to the private interface used by the TLS proxy;
do not expose the application port publicly.

```bash
export OPENPAY_APP_KEY='base64:replace-with-the-generated-key'
export OPENPAY_DB_PASSWORD='replace-with-a-secret-from-your-secret-manager'
export OPENPAY_HTTP_BIND_ADDRESS='127.0.0.1'
export OPENPAY_HTTP_PORT='8080'
docker compose up --build -d
curl --fail http://127.0.0.1:8080/healthz
```

Compose first runs the one-shot `migrate` service. The `app`, `queue`, and
`scheduler` services wait for PostgreSQL health and successful migrations, use
`unless-stopped` restart policies, and share the named `app-storage` volume.
`postgres-data` persists the PostgreSQL cluster. The queue is explicitly
Laravel's `database` driver; no Redis service is required or started.

Terminate TLS before the app with a maintained reverse proxy and certificate
automation. Keep the app port private to that proxy, set
`OPENPAY_APP_URL` to the public `https://` URL, and restrict PostgreSQL to the
Compose network. Do not expose PostgreSQL or the unencrypted application port
to the internet.

## Resources and routine checks

For this four-process baseline, reserve at least 2 vCPU, 4 GiB RAM, and 20 GiB
of durable database storage before application data, then alert on database
volume capacity and host memory. Size storage and backup retention from the
approved data-retention policy; this repository does not authorize a retention
period.

Check service state and liveness after every deployment:

```bash
docker compose ps
curl --fail http://127.0.0.1:8080/healthz
```

The following synthetic probe proves the database queue worker consumes a job
without placing customer data in logs or fixtures. It writes a five-minute
operational cache marker only:

```bash
docker compose exec -T app php artisan openpay:queue-probe
docker compose exec -T app php artisan openpay:queue-probe --assert-consumed
```

## Backup, restore, and upgrades

Back up PostgreSQL before upgrades and store the dump outside the repository in
encrypted, access-controlled storage. The following creates a PostgreSQL custom
format backup; its contents can contain customer data.

```bash
docker compose exec -T postgres pg_dump -U "${OPENPAY_DB_USERNAME:-openpay}" --format=custom "${OPENPAY_DB_DATABASE:-openpay}" > /protected/backups/openpay-$(date +%F).dump
```

Regularly rehearse a restore into an isolated database or environment. The
following restore command is destructive to its target and must never point at
the live database without an approved recovery decision:

```bash
docker compose exec -T postgres createdb -U "${OPENPAY_DB_USERNAME:-openpay}" openpay_restore_smoke
docker compose exec -T postgres pg_restore -U "${OPENPAY_DB_USERNAME:-openpay}" --no-owner --dbname=openpay_restore_smoke < /protected/backups/openpay-YYYY-MM-DD.dump
docker compose exec -T postgres psql -U "${OPENPAY_DB_USERNAME:-openpay}" -d openpay_restore_smoke -c '\\dt'
```

For an upgrade: take and verify a backup, build or pull the reviewed image,
apply migrations with the one-shot service, restart the long-running services,
and repeat the liveness and queue checks. Keep the previous reviewed image tag
available for rollback; database rollbacks require a tested restore plan, not
destructive down migrations.

```bash
docker compose build --pull
docker compose run --rm migrate
docker compose up -d --force-recreate app queue scheduler
```
