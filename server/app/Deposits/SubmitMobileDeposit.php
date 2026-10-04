<?php

declare(strict_types=1);

namespace App\Deposits;

use App\Models\ApprovedSmsParserRelease;
use App\Models\SourceInstallation;
use Carbon\CarbonImmutable;
use Illuminate\Validation\ValidationException;

final readonly class SubmitMobileDeposit
{
    public function __construct(private RecordProviderDeposit $record) {}

    /** @param array<string, mixed> $input */
    public function submit(SourceInstallation $installation, array $input, bool $requireParserEvidence = false): RecordProviderDepositResult
    {
        $input = MobileDepositInput::validate($input, $requireParserEvidence);
        /** @var array{kind: string, provider: string, sms_sender: string, parser_version: int, sms_received_at: string, evidence_digest: string, parser_release_id: string}|null $evidence */
        $evidence = $input['parser_evidence'] ?? null;
        if ($requireParserEvidence && ! is_array($evidence)) {
            throw ValidationException::withMessages(['parser_evidence' => 'A published SMS parser release is required.']);
        }
        if ($evidence !== null) {
            $release = ApprovedSmsParserRelease::query()
                ->where('release_id', $evidence['parser_release_id'])
                ->first();
            $capturedAt = CarbonImmutable::parse($evidence['sms_received_at'], 'UTC');
            if ($release === null
                || ! hash_equals($release->provider, $evidence['provider'])
                || ! hash_equals($release->sender, $evidence['sms_sender'])
                || $release->pattern_version !== $evidence['parser_version']
                || $capturedAt->lessThan($release->approved_at)
                || $capturedAt->greaterThanOrEqualTo($release->expires_at)
                || $capturedAt->greaterThan(now('UTC')->addMinutes(5))
                || (isset($input['sender_identifier']) && $input['sender_identifier'] !== $evidence['sms_sender'])) {
                throw ValidationException::withMessages(['parser_evidence' => 'The SMS parser release is not approved or has expired.']);
            }
        }

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
            parserEvidence: is_array($evidence) ? $evidence : null,
        ), $installation);
    }

    /** @param array<string, mixed> $input */
    private function optionalString(array $input, string $key): ?string
    {
        $value = $input[$key] ?? null;

        return is_string($value) ? $value : null;
    }
}
