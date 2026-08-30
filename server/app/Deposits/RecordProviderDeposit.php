<?php

namespace App\Deposits;

use App\Models\Customer;
use App\Models\Deposit;
use App\Models\LedgerEntry;
use App\Models\PrivateLookupAlias;
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
        $providerReferenceDigests = $this->digests('provider_reference', $transfer->organizationId, $transfer->providerReference);
        $idempotencyDigests = $this->digests('idempotency', $transfer->organizationId, json_encode([
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

        $existing = $this->existing($transfer->organizationId, $providerReferenceDigests);
        if ($existing !== null) {
            return $this->replayResult($existing, $idempotencyDigests);
        }

        for ($attempt = 1; $attempt <= 3; $attempt++) {
            try {
                return DB::transaction(function () use ($transfer, $providerReferenceDigests, $idempotencyDigests): RecordProviderDepositResult {
                    $existing = $this->existing($transfer->organizationId, $providerReferenceDigests, true);
                    if ($existing !== null) {
                        return $this->replayResult($existing, $idempotencyDigests);
                    }

                    event(new ProviderDepositPreflightMissed);

                    $providerReferenceLookupId = $this->resolveLookupId('provider_reference', $transfer->organizationId, $providerReferenceDigests);
                    $existing = $this->existing($transfer->organizationId, $providerReferenceDigests, true, $providerReferenceLookupId);
                    if ($existing !== null) {
                        return $this->replayResult($existing, $idempotencyDigests);
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
                        'provider_reference_digest' => $this->activeDigest($providerReferenceDigests),
                        'provider_reference_lookup_id' => $providerReferenceLookupId,
                        'provider_reference_key_version' => $this->activeKeyId(),
                        'provider_occurred_at' => CarbonImmutable::parse($transfer->providerOccurredAt),
                        'received_at' => $receivedAt,
                        'sender_identifier' => $transfer->senderIdentifier,
                        'receiver_identifier' => $transfer->receiverIdentifier,
                        'idempotency_digest' => $this->activeDigest($idempotencyDigests),
                        'idempotency_key_version' => $this->activeKeyId(),
                    ]);
                    $this->appendEntries($deposit, $receivedAt, false);

                    return new RecordProviderDepositResult(RecordResult::Recorded, $deposit);
                }, attempts: 3);
            } catch (QueryException $exception) {
                $existing = $this->existing($transfer->organizationId, $providerReferenceDigests);
                if ($existing !== null) {
                    return $this->replayResult($existing, $idempotencyDigests);
                }

                if ($attempt < 3 && $this->isRetryableTransactionFailure($exception)) {
                    continue;
                }

                throw $exception;
            }
        }

        throw new LogicException('Provider deposit recording retry limit was exhausted.');
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
                    'idempotency_digest' => $this->activeDigest($this->digests('reversal', $original->organization_id, $original->id)),
                    'idempotency_key_version' => $this->activeKeyId(),
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

    /** @param array<string, string> $providerReferenceDigests */
    private function existing(string $organizationId, array $providerReferenceDigests, bool $lock = false, ?string $lookupId = null): ?Deposit
    {
        $query = Deposit::query()
            ->where('organization_id', $organizationId);

        $query->where(function ($query) use ($providerReferenceDigests, $lookupId): void {
            $query->whereIn('provider_reference_digest', array_values($providerReferenceDigests));
            if ($lookupId !== null) {
                $query->orWhere('provider_reference_lookup_id', $lookupId);
            }
        });

        return $lock ? $query->lockForUpdate()->first() : $query->first();
    }

    /** @param array<string, string> $idempotencyDigests */
    private function replayResult(Deposit $deposit, array $idempotencyDigests): RecordProviderDepositResult
    {
        return new RecordProviderDepositResult(
            in_array($deposit->idempotency_digest, $idempotencyDigests, true) ? RecordResult::Replayed : RecordResult::Conflict,
            $deposit,
        );
    }

    private function customer(ProviderTransfer $transfer): Customer
    {
        $digests = $this->digests('customer_lookup', $transfer->organizationId, $transfer->customerLookupIdentifier);

        $lookupId = $this->resolveLookupId('customer_lookup', $transfer->organizationId, $digests);

        return Customer::query()->createOrFirst(
            ['organization_id' => $transfer->organizationId, 'private_lookup_id' => $lookupId],
            ['private_lookup_digest' => $this->activeDigest($digests), 'private_lookup_key_version' => $this->activeKeyId()],
        );
    }

    private function installation(ProviderTransfer $transfer): SourceInstallation
    {
        $digests = $this->digests('installation_lookup', $transfer->organizationId, $transfer->installationIdentifier);

        $lookupId = $this->resolveLookupId('installation_lookup', $transfer->organizationId, $digests);

        return SourceInstallation::query()->createOrFirst(
            ['organization_id' => $transfer->organizationId, 'installation_lookup_id' => $lookupId],
            ['installation_digest' => $this->activeDigest($digests), 'installation_key_version' => $this->activeKeyId()],
        );
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

    /** @param array<string, string> $digests */
    private function resolveLookupId(string $purpose, string $organizationId, array $digests): string
    {
        ksort($digests);
        if ($digests === []) {
            throw new LogicException('Deposit lookup-token key ring is not configured.');
        }

        $lookupIds = PrivateLookupAlias::query()->where('organization_id', $organizationId)->where('purpose', $purpose)
            ->whereIn('digest', array_values($digests))->pluck('lookup_id')->unique()->values();
        if ($lookupIds->count() > 1) {
            throw new LogicException('Deposit lookup aliases are inconsistent.');
        }
        $lookupId = $lookupIds->first() ?? (string) Str::uuid();
        $createdWithoutExistingAlias = $lookupIds->isEmpty();

        foreach ($digests as $index => $digest) {
            $alias = PrivateLookupAlias::query()->createOrFirst(
                ['organization_id' => $organizationId, 'purpose' => $purpose, 'digest' => $digest],
                ['lookup_id' => $lookupId, 'created_at' => CarbonImmutable::now()],
            );

            if ($alias->lookup_id !== $lookupId) {
                if ($index === array_key_first($digests) && $createdWithoutExistingAlias) {
                    $lookupId = $alias->lookup_id;

                    continue;
                }

                throw new LogicException('Deposit lookup aliases are inconsistent.');
            }
        }

        return $lookupId;
    }

    private function isRetryableTransactionFailure(QueryException $exception): bool
    {
        $driverErrorCode = $exception->errorInfo[1] ?? null;

        return in_array($exception->getCode(), ['23000', '23505'], true)
            || (is_int($driverErrorCode) || is_string($driverErrorCode)) && (string) $driverErrorCode === '1020';
    }

    /** @return array<string, string> */
    private function digests(string $purpose, string $organizationId, string $value): array
    {
        $digests = [];
        foreach ($this->keyRing() as $keyId => $key) {
            $digests[$keyId] = hash_hmac('sha256', json_encode([
                'version' => 'openpay.lookup.v1',
                'purpose' => $purpose,
                'organization_id' => $organizationId,
                'value' => $value,
            ], JSON_THROW_ON_ERROR), $key);
        }

        return $digests;
    }

    /** @param array<string, string> $digests */
    private function activeDigest(array $digests): string
    {
        return $digests[$this->activeKeyId()];
    }

    private function activeKeyId(): string
    {
        $configured = config('deposits.lookup_token_active_key_id');

        return is_string($configured) && $configured !== '' ? $configured : 'v1';
    }

    /** @return array<string, string> */
    private function keyRing(): array
    {
        $configured = config('deposits.lookup_token_keys');
        if (is_string($configured) && $configured !== '') {
            try {
                $configured = json_decode($configured, true, 512, JSON_THROW_ON_ERROR);
            } catch (\JsonException) {
                throw new LogicException('Deposit lookup-token key ring is not configured.');
            }
        }

        if ($configured === null || $configured === []) {
            $configured = ['v1' => config('deposits.lookup_token_key')];
        }

        if (! is_array($configured)) {
            throw new LogicException('Deposit lookup-token key ring is not configured.');
        }

        $ring = [];
        foreach ($configured as $keyId => $key) {
            $keyId = (string) $keyId;
            if (preg_match('/^[A-Za-z0-9._-]{1,64}$/D', $keyId) !== 1 || ! is_string($key) || mb_strlen($key) < 32) {
                throw new LogicException('Deposit lookup-token key ring is not configured.');
            }

            $ring[$keyId] = $key;
        }

        if (! array_key_exists($this->activeKeyId(), $ring)) {
            throw new LogicException('Deposit lookup-token key ring is not configured.');
        }

        return $ring;
    }
}
