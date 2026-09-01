<?php

declare(strict_types=1);

namespace App\Pairing;

use App\Models\User;

final class PairingIntentIssuanceLimiter
{
    private const MAX_ATTEMPTS = 5;

    private const DECAY_SECONDS = 60;

    public function __construct(private readonly PairingRateLimitAdmission $admission) {}

    public function consume(User $issuer): void
    {
        $key = $this->key($issuer);

        try {
            $retryAfter = $this->admission->consume($key, self::MAX_ATTEMPTS, self::DECAY_SECONDS);
        } catch (PairingRateLimitAdmissionUnavailable) {
            throw new PairingIntentRateLimited(1);
        }

        if ($retryAfter === null) {
            return;
        }

        throw new PairingIntentRateLimited($retryAfter);
    }

    private function key(User $issuer): string
    {
        return 'pairing-intents:'.$issuer->getAuthIdentifier().':'.$issuer->organization_id;
    }
}
