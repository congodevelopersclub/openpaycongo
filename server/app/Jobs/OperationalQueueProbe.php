<?php

declare(strict_types=1);

namespace App\Jobs;

use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Cache\Repository;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;

final class OperationalQueueProbe implements ShouldQueue
{
    use Dispatchable;
    use InteractsWithQueue;
    use Queueable;
    use SerializesModels;

    public function __construct(public readonly string $probeId) {}

    public static function cacheKey(string $probeId): string
    {
        return 'operational-queue-probe:'.$probeId;
    }

    public function handle(Repository $cache): void
    {
        $cache->put(self::cacheKey($this->probeId), 'consumed', now()->addMinutes(5));
    }
}
