<?php

declare(strict_types=1);

namespace App\Console\Commands;

use App\Jobs\OperationalQueueProbe;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Cache;

final class ProbeDatabaseQueue extends Command
{
    protected $signature = 'openpay:queue-probe {--assert-consumed : Fail unless the worker consumed the probe}';

    protected $description = 'Dispatch or verify a synthetic database queue probe.';

    public function handle(): int
    {
        if ($this->option('assert-consumed')) {
            if (! Cache::has('operational-queue-probe')) {
                $this->components->error('Database queue probe has not been consumed.');

                return self::FAILURE;
            }

            $this->components->info('Database queue probe consumed.');

            return self::SUCCESS;
        }

        OperationalQueueProbe::dispatch();
        $this->components->info('Database queue probe dispatched.');

        return self::SUCCESS;
    }
}
