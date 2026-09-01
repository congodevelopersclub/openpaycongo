<?php

declare(strict_types=1);

namespace App\Pairing;

use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\RateLimiter;

final class PairingRateLimitAdmission
{
    private const int LOCK_SECONDS = 5;

    /**
     * Consume one quota slot atomically.
     *
     * @return int|null Seconds until the active window resets, or null when admitted.
     */
    public function consume(string $key, int $maxAttempts, int $decaySeconds): ?int
    {
        $lock = Cache::lock($key.':admission', self::LOCK_SECONDS);
        if (! $lock->get()) {
            throw new PairingRateLimitAdmissionUnavailable;
        }

        try {
            if (RateLimiter::tooManyAttempts($key, $maxAttempts)) {
                return RateLimiter::availableIn($key);
            }

            RateLimiter::hit($key, $decaySeconds);

            return null;
        } finally {
            $lock->release();
        }
    }
}
