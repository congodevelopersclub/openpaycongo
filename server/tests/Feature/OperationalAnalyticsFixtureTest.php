<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\Operations\MigrationReadiness;
use App\Operations\ProjectionReadiness;
use App\Support\CanonicalAnalyticsFixture;
use Illuminate\Foundation\Testing\RefreshDatabase;
use RuntimeException;
use Tests\TestCase;

final class OperationalAnalyticsFixtureTest extends TestCase
{
    use RefreshDatabase;

    public function test_ready_stack_reports_live_dependencies_and_admits_writes(): void
    {
        $this->getJson('/healthz')->assertOk()->assertExactJson(['status' => 'ok']);
        $this->getJson('/readyz')
            ->assertOk()
            ->assertHeader('cache-control', 'no-store, private')
            ->assertJson([
                'datastore' => 'ok',
                'migration' => 'current',
                'topology' => 'supported',
                'projection' => 'healthy',
                'write_admission' => 'open',
                'adapter' => 'sqlite',
                'implementation' => 'congo-openpay-server',
            ]);
        $this->getJson('/version')
            ->assertOk()
            ->assertHeader('cache-control', 'no-store, private');
    }

    public function test_projection_dependency_failure_closes_readiness(): void
    {
        $this->app->instance(ProjectionReadiness::class, new class implements ProjectionReadiness
        {
            public function status(): string
            {
                return 'failed';
            }
        });

        $this->getJson('/readyz')
            ->assertStatus(503)
            ->assertHeader('cache-control', 'no-store, private')
            ->assertJson([
                'datastore' => 'failed',
                'migration' => 'failed',
                'projection' => 'failed',
                'write_admission' => 'closed',
            ]);
    }

    public function test_projection_exception_fails_readiness_closed_without_leaking_details(): void
    {
        $this->app->instance(ProjectionReadiness::class, new class implements ProjectionReadiness
        {
            public function status(): string
            {
                throw new RuntimeException('projection connection details');
            }
        });

        $this->getJson('/readyz')
            ->assertStatus(503)
            ->assertJson([
                'datastore' => 'failed',
                'migration' => 'failed',
                'projection' => 'failed',
                'write_admission' => 'closed',
            ])
            ->assertJsonMissing(['message' => 'projection connection details']);
    }

    public function test_late_migration_revision_exception_fails_readiness_closed(): void
    {
        $this->app->instance(MigrationReadiness::class, new class implements MigrationReadiness
        {
            public function status(): string
            {
                return 'current';
            }

            public function revision(): string
            {
                throw new RuntimeException('repository was replaced');
            }
        });

        $this->getJson('/readyz')
            ->assertStatus(503)
            ->assertJson([
                'datastore' => 'failed',
                'migration' => 'failed',
                'projection' => 'failed',
                'write_admission' => 'closed',
            ])
            ->assertJsonMissing(['message' => 'repository was replaced']);
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
