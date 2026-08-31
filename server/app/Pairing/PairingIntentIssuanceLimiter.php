<?php

declare(strict_types=1);

namespace App\Pairing;

use App\Models\User;
use Illuminate\Support\Facades\RateLimiter;

final class PairingIntentIssuanceLimiter
{
    private const MAX_ATTEMPTS = 5;

    private const DECAY_SECONDS = 60;

    public function consume(User $issuer): void
    {
        $key = $this->key($issuer);

        if (RateLimiter::attempt($key, self::MAX_ATTEMPTS, static fn (): bool => true, self::DECAY_SECONDS)) {
            return;
        }

        throw new PairingIntentRateLimited(RateLimiter::availableIn($key));
    }

    private function key(User $issuer): string
    {
        return 'pairing-intents:'.$issuer->getAuthIdentifier().':'.$issuer->organization_id;
    }
}
