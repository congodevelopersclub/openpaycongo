<?php

declare(strict_types=1);

namespace App\Console\Commands;

use App\Jobs\OperationalQueueProbe;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Str;

final class ProbeDatabaseQueue extends Command
{
    protected $signature = 'openpay:queue-probe {--timeout=30 : Seconds to wait for this exact probe to be consumed}';

    protected $description = 'Dispatch and verify a synthetic database queue probe.';

    public function handle(): int
    {
        $probeId = (string) Str::uuid();
        $cacheKey = OperationalQueueProbe::cacheKey($probeId);
        $timeout = max(0, (int) $this->option('timeout'));
        $deadline = microtime(true) + $timeout;

        OperationalQueueProbe::dispatch($probeId);

        do {
            if (Cache::pull($cacheKey) === 'consumed') {
                $this->components->info('Database queue probe consumed.');

                return self::SUCCESS;
            }

            usleep(250_000);
        } while (microtime(true) < $deadline);

        $this->components->error('Database queue probe timed out before its exact marker was consumed.');

        return self::FAILURE;
    }
}
