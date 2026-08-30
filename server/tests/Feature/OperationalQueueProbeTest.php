<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\Jobs\OperationalQueueProbe;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Queue;
use Illuminate\Support\Str;
use Ramsey\Uuid\Uuid;
use Tests\TestCase;

final class OperationalQueueProbeTest extends TestCase
{
    public function test_it_records_a_non_sensitive_marker_for_its_exact_probe_id(): void
    {
        $probe = new OperationalQueueProbe('fresh-probe-id');

        app()->call([$probe, 'handle']);

        self::assertIsString(Cache::get(OperationalQueueProbe::cacheKey('fresh-probe-id')));
        self::assertNull(Cache::get(OperationalQueueProbe::cacheKey('different-probe-id')));
    }

    public function test_it_times_out_when_only_a_stale_probe_marker_exists(): void
    {
        config()->set('queue.default', 'database');
        Cache::put(OperationalQueueProbe::cacheKey('stale-probe-id'), 'consumed', now()->addMinute());
        Queue::fake();

        $exitCode = Artisan::call('openpay:queue-probe', ['--timeout' => 0]);

        self::assertSame(1, $exitCode);
        self::assertTrue(Cache::has(OperationalQueueProbe::cacheKey('stale-probe-id')));
        Queue::assertPushed(function (OperationalQueueProbe $probe): bool {
            return Str::isUuid($probe->probeId);
        });
    }

    public function test_it_consumes_and_removes_the_fresh_marker_from_its_own_command_run(): void
    {
        $probeId = '1093d7fc-b8f6-48ee-92ca-f1f6b4bb1c11';
        config()->set('queue.default', 'sync');
        Str::createUuidsUsing(static fn () => Uuid::fromString($probeId));

        try {
            $exitCode = Artisan::call('openpay:queue-probe', ['--timeout' => 1]);
        } finally {
            Str::createUuidsNormally();
        }

        self::assertSame(0, $exitCode);
        self::assertFalse(Cache::has(OperationalQueueProbe::cacheKey($probeId)));
    }
}
