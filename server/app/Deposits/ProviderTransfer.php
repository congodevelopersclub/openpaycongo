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
        public ?string $customerName = null,
        public ?string $customerAddress = null,
        public ?string $customerPhone = null,
        public ?string $customerEmail = null,
        /** @var array{kind: string, provider: string, sms_sender: string, parser_version: int, sms_received_at: string, evidence_digest: string, parser_release_id: string}|null */
        public ?array $parserEvidence = null,
    ) {}
}
