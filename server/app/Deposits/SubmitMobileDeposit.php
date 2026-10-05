<?php

declare(strict_types=1);

namespace App\Deposits;

use App\Models\OperatorSmsPatternRelease;
use App\Models\SourceInstallation;
use App\OperatorSms\OperatorPaymentPatternContract;
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
            $release = OperatorSmsPatternRelease::query()
                ->where('parser_release_digest', $evidence['parser_release_id'])
                ->where('organization_id', $installation->organization_id)
                ->where('provider', $evidence['provider'])
                ->where('sender', $evidence['sms_sender'])
                ->where('pattern_version', $evidence['parser_version'])
                ->first();
            $proposal = $release?->proposal;
            $capturedAt = CarbonImmutable::parse($evidence['sms_received_at'], 'UTC');
            $signedRelease = $release === null ? null : json_decode($release->encoded_release, true);
            $approvedAt = is_array($signedRelease) && is_string($signedRelease['approved_at'] ?? null)
                && MobileDepositInput::isStrictPortableTimestamp($signedRelease['approved_at'])
                ? CarbonImmutable::parse($signedRelease['approved_at'], 'UTC') : null;
            $expiresAt = is_array($signedRelease) && is_string($signedRelease['expires_at'] ?? null)
                && MobileDepositInput::isStrictPortableTimestamp($signedRelease['expires_at'])
                ? CarbonImmutable::parse($signedRelease['expires_at'], 'UTC') : null;
            if ($release === null || $proposal === null
                || $proposal->organization_id !== $installation->organization_id
                || $proposal->status !== 'approved'
                || $proposal->reviewed_by_user_id === null
                || $proposal->reviewed_at === null
                || ! hash_equals($proposal->template_sha256, hash('sha256', $proposal->template))
                || ! is_array($signedRelease)
                || count($signedRelease) !== 8
                || array_diff(array_keys($signedRelease), ['schema_version', 'provider', 'sender', 'template', 'pattern_version', 'approved_at', 'expires_at', 'signature']) !== []
                || ($signedRelease['schema_version'] ?? null) !== '1'
                || ($signedRelease['provider'] ?? null) !== $evidence['provider']
                || ($signedRelease['sender'] ?? null) !== $evidence['sms_sender']
                || ($signedRelease['pattern_version'] ?? null) !== $evidence['parser_version']
                || ! is_string($signedRelease['signature'] ?? null)
                || preg_match('/^[A-Za-z0-9_-]{86}$/D', $signedRelease['signature']) !== 1
                || ! is_string($signedRelease['template'] ?? null)
                || ! OperatorPaymentPatternContract::validTemplate($signedRelease['template'])
                || $proposal->provider !== $evidence['provider']
                || $proposal->sender !== $evidence['sms_sender']
                || $proposal->template !== $signedRelease['template']
                || CarbonImmutable::parse($proposal->reviewed_at, 'UTC')->startOfSecond()->format('Y-m-d\\TH:i:s\\Z') !== ($signedRelease['approved_at'] ?? null)
                || ! OperatorPaymentPatternContract::validWalletTemplate($signedRelease['template'])
                || $approvedAt === null || $expiresAt === null
                || ! hash_equals($release->parser_release_digest, hash('sha256', OperatorPaymentPatternContract::transcript([
                    'schema_version' => '1',
                    'provider' => $evidence['provider'],
                    'sender' => $evidence['sms_sender'],
                    'template' => $signedRelease['template'],
                    'pattern_version' => $evidence['parser_version'],
                    'approved_at' => $signedRelease['approved_at'],
                    'expires_at' => $signedRelease['expires_at'],
                ])))
                || $expiresAt->lessThanOrEqualTo($approvedAt)
                || $expiresAt->format('Y-m-d\TH:i:s\Z') !== $release->expires_at->utc()->format('Y-m-d\TH:i:s\Z')
                || $capturedAt->lessThan($approvedAt)
                || $capturedAt->greaterThanOrEqualTo($expiresAt)
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
