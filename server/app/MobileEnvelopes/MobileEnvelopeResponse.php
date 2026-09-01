<?php

declare(strict_types=1);

namespace App\MobileEnvelopes;

final readonly class MobileEnvelopeResponse
{
    public function __construct(
        public int $status,
        public string $nonce,
        public string $ciphertext,
    ) {}

    /** @return array{version: int, nonce: string, ciphertext: string} */
    public function outer(): array
    {
        return [
            'version' => 1,
            'nonce' => $this->nonce,
            'ciphertext' => $this->ciphertext,
        ];
    }
}
