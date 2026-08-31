<?php

declare(strict_types=1);

namespace App\Pairing;

use InvalidArgumentException;

final class SecurePairingRandom implements PairingRandom
{
    public function bytes(int $length): string
    {
        if ($length < 1 || $length > 1024) {
            throw new InvalidArgumentException('Invalid random byte length.');
        }

        return random_bytes($length);
    }
}
