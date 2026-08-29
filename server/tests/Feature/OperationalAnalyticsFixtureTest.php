<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\Support\CanonicalAnalyticsFixture;
use Tests\TestCase;

final class OperationalAnalyticsFixtureTest extends TestCase
{
    public function test_operational_routes_are_no_store_and_write_admission_stays_closed(): void
    {
        $this->getJson('/api/healthz')->assertOk()->assertExactJson(['status' => 'ok']);
        $this->getJson('/api/readyz')
            ->assertStatus(503)
            ->assertHeader('cache-control', 'no-store, private')
            ->assertExactJson([
                'datastore' => 'ok',
                'migration' => 'pending',
                'topology' => 'unsupported',
                'projection' => 'unimplemented',
                'write_admission' => 'closed',
                'contract_version' => 'unimplemented',
                'migration_revision' => 'unimplemented',
                'adapter' => 'sqlite',
                'implementation' => 'congo-openpay-server',
            ]);
        $this->getJson('/api/version')
            ->assertOk()
            ->assertHeader('cache-control', 'no-store, private');
    }

    public function test_canonical_analytics_fixture_preserves_decimal_money_and_utc_bounds(): void
    {
        $fixture = app(CanonicalAnalyticsFixture::class)->response();

        self::assertSame('sales-analytics-v1', $fixture['contract_version']);
        self::assertSame('10000', $fixture['current']['currencies'][0]['gross_minor']);
        self::assertSame('2026-11-01T04:00:00Z', $fixture['current']['from']);
        self::assertSame('2026-11-02T05:00:00Z', $fixture['current']['to']);
    }
}
