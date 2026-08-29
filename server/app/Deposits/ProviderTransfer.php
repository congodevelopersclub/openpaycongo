<?php

namespace App\Deposits;

final readonly class ProviderTransfer
{
    public function __construct(
        public string $organizationId,
        public string $installationIdentifier,
        public string $customerLookupIdentifier,
        public string $providerReference,
        public int $amountMinor,
        public string $currency,
        public string $providerOccurredAt,
        public ?string $senderIdentifier,
        public ?string $receiverIdentifier,
    ) {}
}
