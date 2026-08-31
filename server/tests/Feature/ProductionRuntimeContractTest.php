<?php

declare(strict_types=1);

namespace Tests\Feature;

use Tests\TestCase;

final class ProductionRuntimeContractTest extends TestCase
{
    public function test_production_configuration_uses_pinned_fpm_and_nginx_and_rejects_builtin_php_servers(): void
    {
        $dockerfile = file_get_contents(base_path('Dockerfile'));
        $compose = file_get_contents(file_exists('/compose.yaml') ? '/compose.yaml' : dirname(base_path()).'/compose.yaml');
        $nginxDockerfile = file_get_contents(base_path('docker/nginx.Dockerfile'));
        $nginxTemplate = file_get_contents(base_path('docker/nginx.conf.template'));
        $nginxProxyMap = file_get_contents(base_path('docker/nginx-proxy-map.conf.template'));
        $proxyRenderer = file_get_contents(base_path('docker/10-openpay-proxies.sh'));

        self::assertIsString($dockerfile);
        self::assertIsString($compose);
        $compose = str_replace("\r\n", "\n", $compose);
        self::assertIsString($nginxDockerfile);
        self::assertIsString($nginxTemplate);
        self::assertIsString($nginxProxyMap);
        self::assertIsString($proxyRenderer);
        self::assertStringContainsString('php:8.3-fpm-alpine@sha256:', $dockerfile);
        self::assertStringContainsString('FROM node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32 AS assets', $dockerfile);
        self::assertStringContainsString('RUN npm ci --ignore-scripts --no-audit --no-fund', $dockerfile);
        self::assertStringContainsString('COPY --from=assets /app/public/build ./public/build', $dockerfile);
        self::assertStringContainsString('FROM php83-platform-check AS production-dependencies', $dockerfile);
        self::assertStringContainsString("COPY server/composer.json server/composer.lock ./\nRUN composer install --no-dev --no-interaction --prefer-dist --no-scripts\n\nCOPY server/ ./", $dockerfile);
        self::assertStringContainsString('pdo_pgsql pdo_mysql pdo_sqlite pcntl', $dockerfile);
        self::assertStringContainsString('FROM production AS production-contract', $dockerfile);
        self::assertStringNotContainsString('production-security-contract', $dockerfile);
        self::assertStringContainsString('test -f composer.json', $dockerfile);
        self::assertStringContainsString('test -f composer.lock', $dockerfile);
        self::assertStringContainsString('test -f public/build/manifest.json', $dockerfile);
        self::assertStringNotContainsString('COPY --chown=www-data:www-data --from=production-dependencies /app ./', $dockerfile);
        self::assertStringContainsString('test ! -e node_modules', $dockerfile);
        self::assertStringContainsString('test ! -e vendor/.openpay-host-dependency-marker', $dockerfile);
        self::assertStringContainsString('test ! -e storage/oauth-private.key', $dockerfile);
        self::assertStringContainsString('test ! -e storage/oauth-public.key', $dockerfile);
        self::assertStringContainsString('test ! -w /var/www/html/vendor', $dockerfile);
        self::assertStringContainsString('test -w /var/www/html/storage', $dockerfile);
        self::assertStringContainsString('test -w /var/www/html/bootstrap/cache', $dockerfile);
        $dockerignore = file_get_contents('/dockerignore');
        self::assertIsString($dockerignore);
        self::assertStringContainsString('server/vendor', $dockerignore);
        self::assertStringContainsString('server/node_modules', $dockerignore);
        self::assertStringContainsString('${OPENPAY_APP_KEY:?Set OPENPAY_APP_KEY outside the repository}', $compose);
        self::assertStringContainsString('OPENPAY_APP_URL: ${OPENPAY_APP_URL:?Set OPENPAY_APP_URL outside the repository}', $compose);
        self::assertStringContainsString('OPENPAY_PASSKEY_RP_ID: ${OPENPAY_PASSKEY_RP_ID:?Set OPENPAY_PASSKEY_RP_ID outside the repository}', $compose);
        self::assertStringContainsString('OPENPAY_PASSKEY_ALLOWED_ORIGINS: ${OPENPAY_PASSKEY_ALLOWED_ORIGINS:?Set OPENPAY_PASSKEY_ALLOWED_ORIGINS outside the repository}', $compose);
        self::assertStringContainsString('OPENPAY_PASSKEY_USER_HANDLE_SECRET: ${OPENPAY_PASSKEY_USER_HANDLE_SECRET:?Set OPENPAY_PASSKEY_USER_HANDLE_SECRET outside the repository}', $compose);
        self::assertStringContainsString('OPENPAY_PASSPORT_KEYS_PATH: /run/secrets', $compose);
        self::assertStringContainsString('x-passport-key-secrets: &passport-key-secrets', $compose);
        self::assertStringContainsString('secrets: *passport-key-secrets', $compose);
        self::assertStringContainsString('target: oauth-private.key', $compose);
        self::assertStringContainsString('target: oauth-public.key', $compose);
        self::assertStringNotContainsString('mode: 0444', $compose);
        self::assertStringContainsString('OPENPAY_PASSPORT_PRIVATE_KEY_FILE:?Set OPENPAY_PASSPORT_PRIVATE_KEY_FILE outside the repository', $compose);
        self::assertStringContainsString('OPENPAY_PASSPORT_PUBLIC_KEY_FILE:?Set OPENPAY_PASSPORT_PUBLIC_KEY_FILE outside the repository', $compose);
        self::assertStringNotContainsString('PASSPORT_PRIVATE_KEY:', $compose);
        self::assertStringNotContainsString('PASSPORT_PUBLIC_KEY:', $compose);
        self::assertStringNotContainsString('passport:keys', $compose);
        self::assertStringContainsString('${DEPOSIT_LOOKUP_TOKEN_KEY:?Set DEPOSIT_LOOKUP_TOKEN_KEY outside the repository}', $compose);
        self::assertStringContainsString('DEPOSIT_LOOKUP_TOKEN_KEYS: ${DEPOSIT_LOOKUP_TOKEN_KEYS:-}', $compose);
        self::assertStringContainsString('DEPOSIT_LOOKUP_TOKEN_ACTIVE_KEY_ID: ${DEPOSIT_LOOKUP_TOKEN_ACTIVE_KEY_ID:-}', $compose);
        self::assertStringContainsString('PAYMENT_REQUEST_IDEMPOTENCY_KEYS: ${PAYMENT_REQUEST_IDEMPOTENCY_KEYS:-}', $compose);
        self::assertStringContainsString('PAYMENT_REQUEST_IDEMPOTENCY_ACTIVE_KEY_ID: ${PAYMENT_REQUEST_IDEMPOTENCY_ACTIVE_KEY_ID:-}', $compose);
        self::assertStringContainsString('SESSION_SECURE_COOKIE: "true"', $compose);
        self::assertMatchesRegularExpression('/postgres:16-alpine@sha256:[a-f0-9]{64}/', $compose);
        self::assertStringContainsString('nginx:', $compose);
        self::assertStringContainsString('dockerfile: server/docker/nginx.Dockerfile', $compose);
        self::assertMatchesRegularExpression('/nginx:\r?\n    build:\r?\n      context: \.\r?\n      dockerfile: server\/docker\/nginx\.Dockerfile\r?\n      target: production/', $compose);
        self::assertStringContainsString('dockerfile: server/Dockerfile', $compose);
        self::assertStringContainsString('php:9000', $nginxTemplate);
        self::assertStringContainsString('location ~ /\\.(?!well-known(?:/|$))', $nginxTemplate);
        self::assertStringContainsString('return 404;', $nginxTemplate);
        self::assertStringContainsString('__OPENPAY_TRUSTED_PROXY_DIRECTIVES__', $nginxTemplate);
        self::assertStringContainsString('$realip_remote_addr', $nginxTemplate);
        self::assertStringContainsString('$openpay_forwarded_proto', $nginxTemplate);
        self::assertStringContainsString('geo $realip_remote_addr $openpay_trusted_proxy', $nginxProxyMap);
        self::assertStringContainsString('"~^1:https$" https;', $nginxProxyMap);
        self::assertStringContainsString('OPENPAY_TRUSTED_PROXY_CIDRS', $proxyRenderer);
        self::assertStringNotContainsString('private_ranges', $nginxTemplate.$proxyRenderer);
        $bootstrap = file_get_contents(base_path('bootstrap/app.php'));
        self::assertIsString($bootstrap);
        self::assertStringContainsString('Request::HEADER_X_FORWARDED_FOR', $bootstrap);
        self::assertStringContainsString('Request::HEADER_X_FORWARDED_PROTO', $bootstrap);
        self::assertStringNotContainsString('Request::HEADER_X_FORWARDED_HOST', $bootstrap);
        self::assertStringNotContainsString('Request::HEADER_X_FORWARDED_PORT', $bootstrap);
        self::assertStringContainsString('${OPENPAY_TRUSTED_PROXY_CIDRS:-127.0.0.1/32}', $compose);
        self::assertSame(2, substr_count($compose, '${OPENPAY_TRUSTED_PROXY_CIDRS:-127.0.0.1/32}'));
        $workflow = file_get_contents('/ci.yml');
        self::assertIsString($workflow);
        self::assertStringContainsString('bash scripts/ci/fast-feedback.sh pr laravel', $workflow);
        $runner = file_get_contents('/scripts/ci/fast-feedback.sh');
        self::assertIsString($runner);
        self::assertStringContainsString('--target production-contract -f server/Dockerfile .', $runner);
        self::assertStringContainsString("export OPENPAY_PASSKEY_ALLOWED_ORIGINS='[\"https://openpay.test\"]'", $runner);
        self::assertStringContainsString('aquasec/trivy@sha256:bcc376de8d77cfe086a917230e818dc9f8528e3c852f7b1aff648949b6258d1c', $runner);
        self::assertStringContainsString('congo-openpay-fpm:ci', $runner);
        self::assertStringContainsString('congo-openpay-nginx:ci', $runner);
        self::assertStringContainsString('--target production --tag congo-openpay-nginx:ci -f server/docker/nginx.Dockerfile .', $runner);
        self::assertStringContainsString('server/vendor/.openpay-host-dependency-marker', $runner);
        self::assertStringContainsString('server/node_modules/.openpay-host-dependency-marker', $runner);
        self::assertStringContainsString('--target production-contract -f server/docker/nginx.Dockerfile .', $runner);
        self::assertStringContainsString('php artisan config:cache', $runner);
        self::assertStringContainsString('OPENPAY_PASSPORT_KEYS_PATH=/run/secrets', $runner);
        self::assertStringContainsString('dst=/run/secrets,readonly', $runner);
        self::assertStringContainsString('mktemp -d', $runner);
        self::assertStringContainsString('chmod 0755 "$passport_key_directory"', $runner);
        self::assertStringContainsString('--user root', $runner);
        self::assertStringContainsString('OPENPAY_PASSPORT_KEYS_PATH=/run/openpay-ci-keys', $runner);
        self::assertStringContainsString('php artisan passport:keys', $runner);
        self::assertStringContainsString('chown "$(id -u www-data):$(id -g www-data)"', $runner);
        self::assertStringContainsString('chmod 0400 /run/openpay-ci-keys/oauth-private.key', $runner);
        self::assertStringContainsString('chmod 0444 /run/openpay-ci-keys/oauth-public.key', $runner);
        self::assertStringContainsString('openssl pkey -in /run/secrets/oauth-private.key -check -noout', $runner);
        self::assertStringContainsString('openssl pkey -pubin -in /run/secrets/oauth-public.key -noout', $runner);
        self::assertStringContainsString('php artisan config:show openpay > /tmp/openpay-openpay', $runner);
        self::assertStringContainsString('passport_keys_path', $runner);
        self::assertStringContainsString('OPENPAY_PASSKEY_USER_HANDLE_SECRET', $runner);
        self::assertStringContainsString("export OPENPAY_PASSPORT_PRIVATE_KEY_FILE='/tmp/openpay-passport-private-key'", $runner);
        self::assertStringContainsString("export OPENPAY_PASSPORT_PUBLIC_KEY_FILE='/tmp/openpay-passport-public-key'", $runner);
        self::assertStringContainsString('OPENPAY_PASSPORT_PRIVATE_KEY_FILE OPENPAY_PASSPORT_PUBLIC_KEY_FILE', $runner);
        self::assertStringContainsString('bash scripts/ci/run-initial-setup-browser.sh', $runner);
        self::assertStringNotContainsString('production-security-contract', $workflow);
        self::assertStringNotContainsString('chown -R nginx:nginx /var/cache/nginx /var/www/html/public', $nginxDockerfile);
        self::assertStringContainsString('chown -R nginx:nginx /var/cache/nginx', $nginxDockerfile);
        self::assertStringContainsString('FROM production AS production-contract', $nginxDockerfile);
        self::assertStringContainsString('test ! -w /var/www/html/public/index.php', $nginxDockerfile);
        self::assertStringContainsString('test ! -w /var/www/html/public/.htaccess', $nginxDockerfile);
        self::assertStringContainsString('test -w /var/cache/nginx', $nginxDockerfile);
        self::assertMatchesRegularExpression('/^FROM (?!production(?:-contract)?\b)[^\s]+@sha256:[a-f0-9]{64}/m', $dockerfile);
        self::assertDoesNotMatchRegularExpression('/(?:php\s+-S|artisan\s+serve)/', $dockerfile.$compose);
        self::assertStringNotContainsString('frankenphp', $dockerfile.$compose);
        self::assertStringNotContainsString('Caddyfile', $dockerfile.$compose);
    }

    public function test_operator_instructions_provision_passport_keys_before_compose_uses_them(): void
    {
        $operations = file_get_contents('/docs/operations.md');

        self::assertIsString($operations);
        self::assertStringContainsString('docker build --target production --tag congo-openpay-fpm:local -f server/Dockerfile .', $operations);
        self::assertStringNotContainsString('docker compose build php', $operations);
        self::assertStringContainsString('--user root', $operations);
        self::assertStringContainsString('chown "$(id -u www-data):$(id -g www-data)"', $operations);
        self::assertStringContainsString('chmod 0400 /run/openpay-passport-keys/oauth-private.key', $operations);
        self::assertStringContainsString('chmod 0444 /run/openpay-passport-keys/oauth-public.key', $operations);
        self::assertStringContainsString('export OPENPAY_PASSPORT_PRIVATE_KEY_FILE="$OPENPAY_PASSPORT_KEYS_DIR/oauth-private.key"', $operations);
        self::assertStringContainsString('export OPENPAY_PASSPORT_PUBLIC_KEY_FILE="$OPENPAY_PASSPORT_KEYS_DIR/oauth-public.key"', $operations);
        self::assertLessThan(
            strpos($operations, 'docker compose up --build -d'),
            strpos($operations, 'docker build --target production --tag congo-openpay-fpm:local -f server/Dockerfile .'),
        );
    }
}
