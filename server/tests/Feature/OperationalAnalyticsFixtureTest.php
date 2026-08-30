<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\Operations\MigrationReadiness;
use App\Operations\ProjectionReadiness;
use App\Support\CanonicalAnalyticsFixture;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Route;
use RuntimeException;
use Tests\TestCase;

final class OperationalAnalyticsFixtureTest extends TestCase
{
    use RefreshDatabase;

    public function test_ready_stack_reports_live_dependencies_and_admits_writes(): void
    {
        $expectedRevision = '2026_09_02_000000_add_reconciliation_correction_evidence';
        $this->getJson('/healthz')->assertOk()->assertExactJson(['status' => 'ok']);
        $ready = $this->getJson('/readyz')
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
                'migration_revision' => $expectedRevision,
            ]);
        $originalConnection = config('database.default');
        config(['database.default' => 'pgsql']);
        $version = $this->getJson('/version');
        config(['database.default' => $originalConnection]);

        $version
            ->assertOk()
            ->assertHeader('cache-control', 'no-store, private')
            ->assertJson([
                'adapter' => 'pgsql',
                'migration_revision' => $expectedRevision,
            ]);

        self::assertSame($ready->json('migration_revision'), $version->json('migration_revision'));
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

    public function test_database_ahead_migration_ledger_closes_readiness(): void
    {
        DB::table('migrations')->insert([
            'migration' => '2099_01_01_000000_removed_migration',
            'batch' => 999,
        ]);

        $this->getJson('/readyz')
            ->assertStatus(503)
            ->assertJson([
                'datastore' => 'failed',
                'migration' => 'failed',
                'projection' => 'failed',
                'write_admission' => 'closed',
            ]);

        $this->getJson('/version')
            ->assertOk()
            ->assertJson(['migration_revision' => '2026_09_02_000000_add_reconciliation_correction_evidence']);
    }

    public function test_trusted_proxy_https_forwarding_is_recognized(): void
    {
        Route::get('/_test/forwarded-scheme', static fn (Request $request) => ['secure' => $request->isSecure()]);

        $this->withServerVariables([
            'REMOTE_ADDR' => '127.0.0.1',
            'HTTP_X_FORWARDED_PROTO' => 'https',
        ])->getJson('/_test/forwarded-scheme')
            ->assertOk()
            ->assertExactJson(['secure' => true]);
    }

    public function test_trusted_proxy_https_session_cookie_is_secure_http_only_and_lax(): void
    {
        config(['session.secure' => true]);

        Route::middleware('web')->get('/_test/session-cookie', static function (Request $request) {
            $request->session()->put('operational-cookie-test', true);

            return response()->json(['status' => 'ok']);
        });

        $response = $this->withServerVariables([
            'REMOTE_ADDR' => '127.0.0.1',
            'HTTP_X_FORWARDED_PROTO' => 'https',
        ])->getJson('/_test/session-cookie')
            ->assertOk();

        $cookie = collect($response->headers->getCookies())
            ->first(static fn ($cookie): bool => $cookie->getName() === config('session.cookie'));

        self::assertNotNull($cookie);
        self::assertTrue($cookie->isSecure());
        self::assertTrue($cookie->isHttpOnly());
        self::assertSame('lax', $cookie->getSameSite());
    }

    public function test_untrusted_forged_https_forwarding_is_not_recognized(): void
    {
        Route::get('/_test/untrusted-forwarded-scheme', static fn (Request $request) => ['secure' => $request->isSecure()]);

        $this->withServerVariables([
            'REMOTE_ADDR' => '203.0.113.50',
            'HTTP_X_FORWARDED_PROTO' => 'https',
        ])->getJson('/_test/untrusted-forwarded-scheme')
            ->assertOk()
            ->assertExactJson(['secure' => false]);
    }

    public function test_forwarded_host_and_port_do_not_override_the_request(): void
    {
        Route::get('/_test/forwarded-authority', static fn (Request $request) => [
            'host' => $request->getHost(),
            'port' => $request->getPort(),
        ]);

        $this->withServerVariables([
            'REMOTE_ADDR' => '127.0.0.1',
            'HTTP_X_FORWARDED_HOST' => 'forged.example',
            'HTTP_X_FORWARDED_PORT' => '444',
        ])->getJson('/_test/forwarded-authority')
            ->assertOk()
            ->assertExactJson([
                'host' => 'localhost',
                'port' => 80,
            ]);
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
