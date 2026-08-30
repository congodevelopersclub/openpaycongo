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
        self::assertStringContainsString('pdo_pgsql pdo_mysql pdo_sqlite pcntl', $dockerfile);
        self::assertStringContainsString('FROM production AS production-contract', $dockerfile);
        self::assertStringNotContainsString('production-security-contract', $dockerfile);
        self::assertStringContainsString('test -f composer.json', $dockerfile);
        self::assertStringContainsString('test -f composer.lock', $dockerfile);
        self::assertStringNotContainsString('COPY --chown=www-data:www-data --from=production-dependencies /app ./', $dockerfile);
        self::assertStringContainsString('test ! -e node_modules', $dockerfile);
        self::assertStringContainsString('test ! -e vendor/.openpay-host-dependency-marker', $dockerfile);
        self::assertStringContainsString('test ! -w /var/www/html/vendor', $dockerfile);
        self::assertStringContainsString('test -w /var/www/html/storage', $dockerfile);
        self::assertStringContainsString('test -w /var/www/html/bootstrap/cache', $dockerfile);
        $dockerignore = file_get_contents('/dockerignore');
        self::assertIsString($dockerignore);
        self::assertStringContainsString('server/vendor', $dockerignore);
        self::assertStringContainsString('server/node_modules', $dockerignore);
        self::assertStringContainsString('${OPENPAY_APP_KEY:?Set OPENPAY_APP_KEY outside the repository}', $compose);
        self::assertStringContainsString('${DEPOSIT_LOOKUP_TOKEN_KEY:?Set DEPOSIT_LOOKUP_TOKEN_KEY outside the repository}', $compose);
        self::assertStringContainsString('DEPOSIT_LOOKUP_TOKEN_KEYS: ${DEPOSIT_LOOKUP_TOKEN_KEYS:-}', $compose);
        self::assertStringContainsString('DEPOSIT_LOOKUP_TOKEN_ACTIVE_KEY_ID: ${DEPOSIT_LOOKUP_TOKEN_ACTIVE_KEY_ID:-}', $compose);
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
        self::assertStringContainsString('--target production-contract -f server/Dockerfile .', $workflow);
        self::assertStringContainsString('Run pinned production image vulnerability scans', $workflow);
        self::assertStringContainsString('aquasec/trivy@sha256:bcc376de8d77cfe086a917230e818dc9f8528e3c852f7b1aff648949b6258d1c', $workflow);
        self::assertStringContainsString('congo-openpay-fpm:ci', $workflow);
        self::assertStringContainsString('congo-openpay-nginx:ci', $workflow);
        self::assertStringContainsString('--target production --tag congo-openpay-nginx:ci -f server/docker/nginx.Dockerfile .', $workflow);
        self::assertStringContainsString('server/vendor/.openpay-host-dependency-marker', $workflow);
        self::assertStringContainsString('server/node_modules/.openpay-host-dependency-marker', $workflow);
        self::assertStringContainsString('--target production-contract -f server/docker/nginx.Dockerfile .', $workflow);
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
}
