<?php

namespace App\Deposits;

use App\Models\Customer;
use App\Models\Deposit;
use App\Models\LedgerEntry;
use App\Models\SourceInstallation;
use Carbon\CarbonImmutable;
use DateTimeImmutable;
use Illuminate\Database\QueryException;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use InvalidArgumentException;
use LogicException;

final class RecordProviderDeposit
{
    public function record(ProviderTransfer $transfer): RecordProviderDepositResult
    {
        $this->assertValid($transfer);
        $transfer = $this->normalise($transfer);
        $this->assertPortableProviderOccurrence($transfer->providerOccurredAt);
        $providerReferenceDigest = $this->digest('provider_reference', $transfer->organizationId, $transfer->providerReference);
        $idempotencyDigest = $this->digest('idempotency', $transfer->organizationId, json_encode([
            'organization_id' => $transfer->organizationId,
            'installation_identifier' => $transfer->installationIdentifier,
            'customer_lookup_identifier' => $transfer->customerLookupIdentifier,
            'provider_reference' => $transfer->providerReference,
            'amount_minor' => $transfer->amountMinor,
            'currency' => $transfer->currency,
            'provider_occurred_at' => $transfer->providerOccurredAt,
            'sender_identifier' => $transfer->senderIdentifier,
            'receiver_identifier' => $transfer->receiverIdentifier,
        ], JSON_THROW_ON_ERROR));

        $existing = $this->existing($transfer->organizationId, $providerReferenceDigest);
        if ($existing !== null) {
            return $this->replayResult($existing, $idempotencyDigest);
        }

        try {
            return DB::transaction(function () use ($transfer, $providerReferenceDigest, $idempotencyDigest): RecordProviderDepositResult {
                $existing = $this->existing($transfer->organizationId, $providerReferenceDigest, true);
                if ($existing !== null) {
                    return $this->replayResult($existing, $idempotencyDigest);
                }

                $customer = $this->customer($transfer);
                $installation = $this->installation($transfer);
                $receivedAt = CarbonImmutable::now();
                $deposit = Deposit::query()->create([
                    'organization_id' => $transfer->organizationId,
                    'customer_id' => $customer->id,
                    'source_installation_id' => $installation->id,
                    'kind' => DepositKind::ProviderCredit->value,
                    'amount_minor' => $transfer->amountMinor,
                    'currency' => strtoupper($transfer->currency),
                    'provider_reference' => $transfer->providerReference,
                    'provider_reference_digest' => $providerReferenceDigest,
                    'provider_occurred_at' => CarbonImmutable::parse($transfer->providerOccurredAt),
                    'received_at' => $receivedAt,
                    'sender_identifier' => $transfer->senderIdentifier,
                    'receiver_identifier' => $transfer->receiverIdentifier,
                    'idempotency_digest' => $idempotencyDigest,
                ]);
                $this->appendEntries($deposit, $receivedAt, false);

                return new RecordProviderDepositResult(RecordResult::Recorded, $deposit);
            }, attempts: 3);
        } catch (QueryException $exception) {
            $existing = $this->existing($transfer->organizationId, $providerReferenceDigest);
            if ($existing !== null) {
                return $this->replayResult($existing, $idempotencyDigest);
            }

            throw $exception;
        }
    }

    public function reverse(Deposit $deposit): ReverseProviderDepositResult
    {
        try {
            return DB::transaction(function () use ($deposit): ReverseProviderDepositResult {
                $original = Deposit::query()->lockForUpdate()->find($deposit->id);
                if ($original === null || $original->kind !== DepositKind::ProviderCredit->value) {
                    throw new InvalidArgumentException('Deposit cannot be reversed.');
                }

                $existing = Deposit::query()->where('reverses_deposit_id', $original->id)->first();
                if ($existing !== null) {
                    return new ReverseProviderDepositResult(ReversalResult::Replayed, $existing);
                }

                $recordedAt = CarbonImmutable::now();
                $reversal = Deposit::query()->create([
                    'organization_id' => $original->organization_id,
                    'customer_id' => $original->customer_id,
                    'source_installation_id' => $original->source_installation_id,
                    'reverses_deposit_id' => $original->id,
                    'kind' => DepositKind::ProviderReversal->value,
                    'amount_minor' => $original->amount_minor,
                    'currency' => $original->currency,
                    'received_at' => $recordedAt,
                    'idempotency_digest' => $this->digest('reversal', $original->organization_id, $original->id),
                ]);
                $this->appendEntries($reversal, $recordedAt, true);

                return new ReverseProviderDepositResult(ReversalResult::Reversed, $reversal);
            }, attempts: 3);
        } catch (QueryException $exception) {
            $existing = Deposit::query()->where('reverses_deposit_id', $deposit->id)->first();
            if ($existing !== null) {
                return new ReverseProviderDepositResult(ReversalResult::Replayed, $existing);
            }

            throw $exception;
        }
    }

    private function assertValid(ProviderTransfer $transfer): void
    {
        if (! Str::isUuid($transfer->organizationId)
            || $transfer->amountMinor < 1
            || ! preg_match('/^[A-Z]{3}$/', $transfer->currency)
            || ! in_array($transfer->currency, (array) config('deposits.supported_currencies'), true)
            || ! $this->isStrictTimestamp($transfer->providerOccurredAt)
            || ! $this->isBoundedIdentifier($transfer->installationIdentifier)
            || ! $this->isBoundedIdentifier($transfer->customerLookupIdentifier)
            || ! $this->isBoundedIdentifier($transfer->providerReference)
            || ! $this->isBoundedIdentifier($transfer->senderIdentifier, true)
            || ! $this->isBoundedIdentifier($transfer->receiverIdentifier, true)) {
            throw new InvalidArgumentException('Invalid provider transfer.');
        }
    }

    private function normalise(ProviderTransfer $transfer): ProviderTransfer
    {
        return new ProviderTransfer(
            organizationId: strtolower(trim($transfer->organizationId)),
            installationIdentifier: trim($transfer->installationIdentifier),
            customerLookupIdentifier: trim($transfer->customerLookupIdentifier),
            providerReference: trim($transfer->providerReference),
            amountMinor: $transfer->amountMinor,
            currency: $transfer->currency,
            providerOccurredAt: CarbonImmutable::parse(trim($transfer->providerOccurredAt))->utc()->toAtomString(),
            senderIdentifier: $transfer->senderIdentifier === null ? null : trim($transfer->senderIdentifier),
            receiverIdentifier: $transfer->receiverIdentifier === null ? null : trim($transfer->receiverIdentifier),
        );
    }

    private function isBoundedIdentifier(?string $value, bool $nullable = false): bool
    {
        if ($value === null) {
            return $nullable;
        }

        return trim($value) !== '' && mb_strlen($value) <= 255 && ! preg_match('/[\x00-\x1F\x7F]/', $value);
    }

    private function isStrictTimestamp(string $value): bool
    {
        if (preg_match('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-](?<hours>\d{2}):(?<minutes>\d{2}))$/D', $value, $offset) !== 1
            || (isset($offset['hours']) && ((int) $offset['hours'] > 23 || (int) $offset['minutes'] > 59))) {
            return false;
        }

        $timestamp = DateTimeImmutable::createFromFormat(DATE_ATOM, $value);
        $errors = DateTimeImmutable::getLastErrors();

        if ($timestamp === false || ($errors !== false && ($errors['warning_count'] !== 0 || $errors['error_count'] !== 0))) {
            return false;
        }

        $canonical = $timestamp->format(DATE_ATOM);

        return $canonical === $value
            || ($timestamp->getOffset() === 0 && $value === substr($canonical, 0, -6).'Z');
    }

    private function assertPortableProviderOccurrence(string $providerOccurredAt): void
    {
        $occurredAt = CarbonImmutable::parse($providerOccurredAt);
        $minimum = CarbonImmutable::create(1000, 1, 1, 0, 0, 0, 'UTC');
        $maximum = CarbonImmutable::create(9999, 12, 31, 23, 59, 59, 'UTC');

        if ($occurredAt->lessThan($minimum) || $occurredAt->greaterThan($maximum)) {
            throw new InvalidArgumentException('Invalid provider transfer.');
        }
    }

    private function existing(string $organizationId, string $providerReferenceDigest, bool $lock = false): ?Deposit
    {
        $query = Deposit::query()
            ->where('organization_id', $organizationId)
            ->where('provider_reference_digest', $providerReferenceDigest);

        return $lock ? $query->lockForUpdate()->first() : $query->first();
    }

    private function replayResult(Deposit $deposit, string $idempotencyDigest): RecordProviderDepositResult
    {
        return new RecordProviderDepositResult(
            $deposit->idempotency_digest === $idempotencyDigest ? RecordResult::Replayed : RecordResult::Conflict,
            $deposit,
        );
    }

    private function customer(ProviderTransfer $transfer): Customer
    {
        $digest = $this->digest('customer_lookup', $transfer->organizationId, $transfer->customerLookupIdentifier);

        return Customer::query()->firstOrCreate([
            'organization_id' => $transfer->organizationId,
            'private_lookup_digest' => $digest,
        ]);
    }

    private function installation(ProviderTransfer $transfer): SourceInstallation
    {
        $digest = $this->digest('installation_lookup', $transfer->organizationId, $transfer->installationIdentifier);

        return SourceInstallation::query()->firstOrCreate([
            'organization_id' => $transfer->organizationId,
            'installation_digest' => $digest,
        ]);
    }

    private function appendEntries(Deposit $deposit, CarbonImmutable $recordedAt, bool $reverse): void
    {
        $amount = (int) $deposit->amount_minor;
        $entries = $reverse
            ? [['account' => 'customer_credit', 'debit_minor' => $amount, 'credit_minor' => 0], ['account' => 'provider_receivable', 'debit_minor' => 0, 'credit_minor' => $amount]]
            : [['account' => 'provider_receivable', 'debit_minor' => $amount, 'credit_minor' => 0], ['account' => 'customer_credit', 'debit_minor' => 0, 'credit_minor' => $amount]];

        foreach ($entries as $entry) {
            LedgerEntry::query()->create([
                'deposit_id' => $deposit->id,
                'organization_id' => $deposit->organization_id,
                'currency' => $deposit->currency,
                'recorded_at' => $recordedAt,
                ...$entry,
            ]);
        }
    }

    private function digest(string $purpose, string $organizationId, string $value): string
    {
        $key = config('deposits.lookup_token_key');
        if (! is_string($key) || mb_strlen($key) < 32) {
            throw new LogicException('Deposit lookup-token key is not configured.');
        }

        return hash_hmac('sha256', json_encode([
            'version' => 'openpay.lookup.v1',
            'purpose' => $purpose,
            'organization_id' => $organizationId,
            'value' => $value,
        ], JSON_THROW_ON_ERROR), $key);
    }
}
