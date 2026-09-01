<?php

declare(strict_types=1);

namespace App\Deposits;

use App\Models\SourceInstallation;

final readonly class SubmitMobileDeposit
{
    public function __construct(private RecordProviderDeposit $record) {}

    /** @param array<string, mixed> $input */
    public function submit(SourceInstallation $installation, array $input): RecordProviderDepositResult
    {
        return $this->record->record(new ProviderTransfer(
            organizationId: $installation->organization_id,
            installationIdentifier: $installation->id,
            customerLookupIdentifier: (string) $input['customer_lookup_identifier'],
            providerReference: (string) $input['provider_reference'],
            amountMinor: (int) $input['amount_minor'],
            currency: (string) $input['currency'],
            providerOccurredAt: (string) $input['provider_occurred_at'],
            senderIdentifier: $this->optionalString($input, 'sender_identifier'),
            receiverIdentifier: $this->optionalString($input, 'receiver_identifier'),
            customerName: $this->optionalString($input, 'customer_name'),
            customerAddress: $this->optionalString($input, 'customer_address'),
            customerPhone: $this->optionalString($input, 'customer_phone'),
            customerEmail: $this->optionalString($input, 'customer_email'),
        ), $installation);
    }

    /** @param array<string, mixed> $input */
    private function optionalString(array $input, string $key): ?string
    {
        $value = $input[$key] ?? null;

        return is_string($value) ? $value : null;
    }
}
