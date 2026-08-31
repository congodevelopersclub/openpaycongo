<?php

declare(strict_types=1);

namespace App\Pairing;

use App\Models\PairingIntent;
use JsonSerializable;

final readonly class IssuedPairingIntent implements JsonSerializable
{
    /** @param array<string, string> $qr */
    public function __construct(public PairingIntent $intent, public array $qr) {}

    /** @return array<string, string> */
    public function jsonSerialize(): array
    {
        return $this->qr;
    }
}
