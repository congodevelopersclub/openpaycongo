# Self-hosted Laravel runtime

`compose.yaml` runs one small PostgreSQL-backed Laravel installation. The
PHP-FPM application image is built in stages, has no development dependencies,
runs as the unprivileged `www-data` user, and writes only to `storage/` and
`bootstrap/cache`. A separate pinned nginx container serves only `public/` and
its Docker health check requests `/healthz`.

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
docker run --rm php:8.3-cli-alpine@sha256:afdf8b1fee58486ccc0dab5f30f634b86873d56dac985f71ba217945647c05ad php -r 'echo "base64:".base64_encode(random_bytes(32)).PHP_EOL;'
```

Set that output and a strong PostgreSQL password in the protected deployment
environment. Compose binds the app only to loopback by default. Set
`OPENPAY_HTTP_BIND_ADDRESS` only to the private interface used by the TLS proxy;
do not expose the application port publicly.

```bash
export OPENPAY_APP_KEY='base64:replace-with-the-generated-key'
export OPENPAY_DB_PASSWORD='replace-with-a-secret-from-your-secret-manager'
export DEPOSIT_LOOKUP_TOKEN_KEY='replace-with-a-distinct-secret-from-your-secret-manager'
export OPENPAY_APP_URL='https://pay.example.com'
export OPENPAY_PASSKEY_RP_ID='pay.example.com'
export OPENPAY_PASSKEY_ALLOWED_ORIGINS='["https://pay.example.com"]'
export OPENPAY_PASSKEY_USER_HANDLE_SECRET='replace-with-a-distinct-32-byte-secret-from-your-secret-manager'
export OPENPAY_HTTP_BIND_ADDRESS='127.0.0.1'
export OPENPAY_HTTP_PORT='8080'
export OPENPAY_TRUSTED_PROXY_CIDRS='127.0.0.1/32'
```

`OPENPAY_APP_URL` is the one canonical public HTTPS origin. Its hostname must
exactly equal `OPENPAY_PASSKEY_RP_ID`, and
`OPENPAY_PASSKEY_ALLOWED_ORIGINS` must be a JSON array containing only that
same origin. `OPENPAY_PASSKEY_USER_HANDLE_SECRET` is distinct from `APP_KEY`,
must be at least 32 bytes, and must come from the secret manager. These four
values are required by this production Compose path; do not substitute a
wildcard, a forwarded host header, or a local HTTP address.

## Passport signing keys

Passport signs and validates service tokens with a stable RSA key pair. The
production image contains neither key and Compose does not put PEM data in
environment variables. Generate the pair once, outside the repository and
outside the image, in a protected host directory. This command uses Passport's
native key generator, refuses to overwrite either existing key, and does not
print key material:

```bash
export OPENPAY_PASSPORT_KEYS_DIR='/protected/openpay/passport'
install -d -m 0700 "$OPENPAY_PASSPORT_KEYS_DIR"
test ! -e "$OPENPAY_PASSPORT_KEYS_DIR/oauth-private.key"
test ! -e "$OPENPAY_PASSPORT_KEYS_DIR/oauth-public.key"
docker build --target production --tag congo-openpay-fpm:local -f server/Dockerfile .
docker run --rm \
  --user root \
  --env APP_ENV=production \
  --env OPENPAY_PASSPORT_KEYS_PATH=/run/openpay-passport-keys \
  --mount type=bind,src="$OPENPAY_PASSPORT_KEYS_DIR",dst=/run/openpay-passport-keys \
  congo-openpay-fpm:local \
  sh -ceu 'umask 077; php artisan passport:keys; chown "$(id -u www-data):$(id -g www-data)" /run/openpay-passport-keys/oauth-private.key /run/openpay-passport-keys/oauth-public.key; chmod 0400 /run/openpay-passport-keys/oauth-private.key; chmod 0444 /run/openpay-passport-keys/oauth-public.key'
export OPENPAY_PASSPORT_PRIVATE_KEY_FILE="$OPENPAY_PASSPORT_KEYS_DIR/oauth-private.key"
export OPENPAY_PASSPORT_PUBLIC_KEY_FILE="$OPENPAY_PASSPORT_KEYS_DIR/oauth-public.key"
docker compose up --build -d
curl --fail http://127.0.0.1:8080/healthz
```

The `php` service mounts those two files as Docker secrets, read-only, at
`/run/secrets/oauth-private.key` and `/run/secrets/oauth-public.key`. It is the
only current process that issues or validates Passport service tokens. Do not
mount the private key into nginx, PostgreSQL, migrations, queue workers, or the
scheduler. Any future process that uses Passport must receive the same
read-only secret pair and be deployed with this configuration. The one-time
generator runs as container root only to write the bind-mounted files with the
numeric ownership of the production `www-data` process. The private key is
owner-readable only; the public key is world-readable. Compose preserves those
source-file permissions for file-backed secrets, so do not change them to a
host-user-owned `0600` pair.

Keep the host directory and its encrypted, access-controlled backup outside
the repository, image, Compose project, logs, shell history, and telemetry.
Runtime recreation does not change these files; loss or replacement changes
the signing identity and can invalidate service tokens. Key rotation, old-key
validation overlap, and revocation policy require an explicit operational
decision; this baseline intentionally does not automate them.

## Legacy administrator provisioning

If this migration is deployed to an installation which already contains users,
public `/setup` stays closed. After migrations complete, an administrator
authenticated to the deployment host may nominate one existing account by its
numeric local user ID (never by email or another identifier that can leak into
shell history):

```bash
docker compose exec -T php php artisan openpay:provision-legacy-operator 123 --force
```

The command locks setup state and refuses an open setup, another operator, or
ambiguous organization ownership. It never reopens `/setup`, creates a
non-secret audit record, and prints no account details. The nominated user must
then sign in, enroll Fortify TOTP, generate and acknowledge recovery codes, and
complete any recommended passkey enrollment before financial operations become
available.

### Pairing a mobile device

After the required TOTP challenge, a verified financial-operator administrator
can use **Operations → Pair mobile device** to create a signed QR code for the
administrator's own organization. Select a lifetime from 30 to 300 seconds and
scan it from the OpenPay Congo mobile app before it expires. The mobile app
verifies the signed QR, but creating or displaying it does not complete pairing
or issue credentials. QR is one-time confidential bootstrap material because it
contains `pairing_secret`; show only to current administrator/phone ceremony,
never retain or copy it. The panel does not display protected server material or
enrollment signing secrets. If issuance is unavailable, retry only from the
panel after checking the service health; the panel intentionally provides no
diagnostic detail.

Compose first runs the one-shot `migrate` service. The `php`, `nginx`, `queue`, and
`scheduler` services wait for PostgreSQL health and successful migrations, use
`unless-stopped` restart policies, and share the named `app-storage` volume.
`postgres-data` persists the PostgreSQL cluster. The queue is explicitly
Laravel's `database` driver; no Redis service is required or started.

Terminate TLS before the app with a maintained reverse proxy and certificate
automation. Keep the app port private to that proxy, set
`OPENPAY_APP_URL` to the public `https://` URL, and restrict PostgreSQL to the
Compose network. Do not expose PostgreSQL or the unencrypted application port
to the internet. Production sets `SESSION_SECURE_COOKIE=true` for the shared
PHP, queue, and scheduler environment, so a browser session requires this TLS
terminator and is never sent over HTTP. nginx trusts forwarded headers from
loopback only by default.
If a TLS proxy needs forwarded-header support, set
`OPENPAY_TRUSTED_PROXY_CIDRS` to a space-separated list containing only that
proxy's exact CIDR addresses (for example, `172.30.0.2/32`). The safe default
is loopback-only. Never use `private_ranges` or a broad private network.
nginx accepts `X-Forwarded-Proto` only from that rendered exact list and passes
the original proxy peer to Laravel; Laravel trusts the same list. Therefore a
direct client cannot forge HTTPS forwarding, while a configured TLS terminator
can make Laravel's secure-request and cookie behavior accurate. This baseline
does not trust forwarded host or port headers; set `OPENPAY_APP_URL` to the
canonical public HTTPS URL instead.

## Resources and routine checks

One clean idle Docker Compose smoke snapshot measured approximately 151 MiB
total resident memory: nginx 13 MiB, PHP-FPM 31 MiB, queue 30 MiB, scheduler
27 MiB, and PostgreSQL 52 MiB. This is an idle observation, not a load or
capacity result.
For a light single-host installation, begin with 1 vCPU and 1 GiB RAM, then
measure the actual workload and alert on host memory, queue latency, and
PostgreSQL volume capacity. Size durable storage and backup retention from the
approved data-retention policy; this repository does not authorize a fixed
storage or retention period.

Check service state and liveness after every deployment:

```bash
docker compose ps
curl --fail http://127.0.0.1:8080/healthz
```

The following synthetic probe proves the database queue worker consumes the
fresh job dispatched by this invocation. It waits for that exact opaque marker,
removes it when observed, and fails on timeout; a stale marker from another run
cannot make it pass. It places no customer data in logs or fixtures:

```bash
docker compose exec -T queue php artisan openpay:queue-probe --timeout=30
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
then use the checked-in quiescent upgrade script. It stops nginx, PHP, queue,
and scheduler before migration; if migration fails it exits nonzero with every
writer still stopped. Lookup-key migration and rotation are not rolling
upgrades: old writers must never run against the migrated schema. Keep the
previous reviewed image tag available for rollback; database rollbacks require
a tested restore plan, not destructive down migrations.

```bash
docker compose build --pull
sh scripts/upgrade-quiescent.sh
```
