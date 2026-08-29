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
        self::assertStringContainsString('dunglas/frankenphp:1.12.7-php8.3-alpine', $dockerfile);
        self::assertStringContainsString('php_server', $caddyfile);
        self::assertStringContainsString('trusted_proxies static private_ranges', $caddyfile);
        self::assertDoesNotMatchRegularExpression('/(?:php\s+-S|artisan\s+serve)/', $dockerfile.$compose);
    }
}
