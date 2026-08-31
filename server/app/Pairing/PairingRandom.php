<?php

declare(strict_types=1);

namespace App\Pairing;

interface PairingRandom
{
    public function bytes(int $length): string;
}
