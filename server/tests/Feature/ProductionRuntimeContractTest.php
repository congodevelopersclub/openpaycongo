<?php

declare(strict_types=1);

namespace Tests\Feature;

use Tests\TestCase;

final class ProductionRuntimeContractTest extends TestCase
{
    public function test_production_configuration_uses_frankenphp_and_rejects_builtin_php_servers(): void
    {
        $dockerfile = file_get_contents(base_path('Dockerfile'));
        $compose = file_get_contents(file_exists('/compose.yaml') ? '/compose.yaml' : dirname(base_path()).'/compose.yaml');
        $caddyfile = file_get_contents(base_path('docker/Caddyfile'));

        self::assertIsString($dockerfile);
        self::assertIsString($compose);
        self::assertIsString($caddyfile);
        self::assertStringContainsString('dunglas/frankenphp:1.12.7-php8.3-alpine@sha256:', $dockerfile);
        self::assertStringContainsString('pdo_pgsql pdo_mysql pdo_sqlite pcntl', $dockerfile);
        self::assertStringContainsString('FROM production AS production-contract', $dockerfile);
        self::assertStringNotContainsString('production-security-contract', $dockerfile);
        self::assertStringContainsString('test -f composer.json', $dockerfile);
        self::assertStringContainsString('test -f composer.lock', $dockerfile);
        self::assertStringContainsString('${OPENPAY_APP_KEY:?Set OPENPAY_APP_KEY outside the repository}', $compose);
        self::assertStringContainsString('${DEPOSIT_LOOKUP_TOKEN_KEY:?Set DEPOSIT_LOOKUP_TOKEN_KEY outside the repository}', $compose);
        self::assertMatchesRegularExpression('/postgres:16-alpine@sha256:[a-f0-9]{64}/', $compose);
        self::assertStringContainsString('php_server', $caddyfile);
        self::assertStringNotContainsString('trusted_proxies static private_ranges', $caddyfile);
        self::assertStringContainsString('trusted_proxies static {$OPENPAY_TRUSTED_PROXY_CIDRS:127.0.0.1/32}', $caddyfile);
        self::assertStringContainsString('trusted_proxies_strict', $caddyfile);
        self::assertStringContainsString('${OPENPAY_TRUSTED_PROXY_CIDRS:-127.0.0.1/32}', $compose);
        $workflow = file_get_contents('/ci.yml');
        self::assertIsString($workflow);
        self::assertStringContainsString('--target production-contract -f server/Dockerfile .', $workflow);
        self::assertStringNotContainsString('production-security-contract', $workflow);
        self::assertMatchesRegularExpression('/^FROM (?!production(?:-contract)?\b)[^\s]+@sha256:[a-f0-9]{64}/m', $dockerfile);
        self::assertDoesNotMatchRegularExpression('/(?:php\s+-S|artisan\s+serve)/', $dockerfile.$compose);
    }
}
