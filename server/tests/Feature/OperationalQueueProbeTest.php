<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\Jobs\OperationalQueueProbe;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Queue;
use Tests\TestCase;

final class OperationalQueueProbeTest extends TestCase
{
    public function test_it_is_dispatched_to_the_database_queue_and_records_a_non_sensitive_probe(): void
    {
        config()->set('queue.default', 'database');

        Queue::fake();
        Artisan::call('openpay:queue-probe');

        Queue::assertPushed(OperationalQueueProbe::class);

        app()->call([new OperationalQueueProbe, 'handle']);

        self::assertIsString(Cache::get('operational-queue-probe'));
    }
}
