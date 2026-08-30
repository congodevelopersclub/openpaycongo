<?php

namespace App\PaymentRequests;

use App\Events\PaymentRequestCreationPreflightMissed;
use App\Models\Customer;
use App\Models\CustomerCredit;
use App\Models\PaymentRequest;
use Carbon\CarbonImmutable;
use Illuminate\Database\QueryException;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use InvalidArgumentException;
use LogicException;

final class CreatePaymentRequest
{
    public function create(string $customerId, int $amountMinor, string $currency, string $idempotencyKey): PaymentRequest
    {
        $customerId = strtolower($customerId);
        $currency = strtoupper($currency);
        if (! Str::isUuid($customerId)
            || $amountMinor < 1
            || preg_match('/^[A-Z]{3}$/D', $currency) !== 1
            || ! in_array($currency, (array) config('deposits.supported_currencies'), true)
            || ! $this->isOpaqueKey($idempotencyKey)) {
            throw new InvalidArgumentException('Invalid payment request.');
        }

        $keyRing = $this->keyRing();
        $activeKeyId = $this->activeKeyId();
        $digests = $this->idempotencyDigests($customerId, $idempotencyKey, $keyRing);
        $digest = $digests[$activeKeyId];
        $activeKeyFingerprint = $this->keyFingerprint($keyRing[$activeKeyId]);
        $configuredKeyFingerprints = array_values(array_map($this->keyFingerprint(...), $keyRing));

        try {
            return DB::transaction(function () use ($customerId, $amountMinor, $currency, $digest, $digests, $activeKeyFingerprint, $configuredKeyFingerprints): PaymentRequest {
                $replay = PaymentRequest::query()->where('customer_id', $customerId)->whereIn('idempotency_digest', array_values($digests))->first();
                if ($replay !== null) {
                    $replay = PaymentRequest::query()->lockForUpdate()->findOrFail($replay->id);

                    return $this->replayOrConflict($this->expireIfDue($replay), $amountMinor, $currency);
                }

                event(new PaymentRequestCreationPreflightMissed($customerId));
                Customer::query()->lockForUpdate()->findOrFail($customerId);

                // Nodes may temporarily use different active key ids during the
                // second phase of rotation. Recheck the complete ring after the
                // customer lock so those writers still serialize to one request.
                $replay = PaymentRequest::query()->where('customer_id', $customerId)->whereIn('idempotency_digest', array_values($digests))->lockForUpdate()->first();
                if ($replay !== null) {
                    return $this->replayOrConflict($this->expireIfDue($replay), $amountMinor, $currency);
                }
                $this->assertPersistedKeyFingerprintsConfigured($customerId, $configuredKeyFingerprints);

                $credit = CustomerCredit::query()
                    ->where('customer_id', $customerId)
                    ->where('currency', $currency)
                    ->lockForUpdate()
                    ->first();
                $now = CarbonImmutable::now();

                if ($credit !== null) {
                    PaymentRequest::query()->where('customer_id', $customerId)->where('currency', $currency)
                        ->where('status', PaymentRequestStatus::Pending)->where('expires_at', '<=', $now)
                        ->update(['status' => PaymentRequestStatus::Expired, 'updated_at' => $now]);

                    $olderRequests = PaymentRequest::query()->where('customer_id', $customerId)->where('currency', $currency)
                        ->where('status', PaymentRequestStatus::Pending)->where('expires_at', '>', $now)
                        ->orderBy('created_at')->orderBy('id')->lockForUpdate()->get();
                    $olderShortfall = false;
                    foreach ($olderRequests as $olderRequest) {
                        if ((int) $credit->available_minor < (int) $olderRequest->remaining_minor) {
                            $olderShortfall = true;
                            break;
                        }
                        $credit->available_minor = (int) $credit->available_minor - (int) $olderRequest->remaining_minor;
                        $olderRequest->remaining_minor = 0;
                        $olderRequest->status = PaymentRequestStatus::Charged->value;
                        $olderRequest->charged_at = $now;
                        $olderRequest->save();
                        app(RecordPaymentRequestAllocation::class)->record($olderRequest->id);
                    }
                    $credit->save();

                    if (! $olderShortfall && (int) $credit->available_minor >= $amountMinor) {
                        $credit->available_minor = (int) $credit->available_minor - $amountMinor;
                        $credit->save();
                        $request = PaymentRequest::query()->create([
                            'customer_id' => $customerId, 'idempotency_digest' => $digest, 'idempotency_key_fingerprint' => $activeKeyFingerprint, 'currency' => $currency,
                            'amount_minor' => $amountMinor, 'remaining_minor' => 0, 'status' => PaymentRequestStatus::Charged,
                            'expires_at' => $now->addDays($this->expiryDays()), 'charged_at' => $now,
                        ]);
                        app(RecordPaymentRequestAllocation::class)->record($request->id);

                        return $request;
                    }
                }

                return PaymentRequest::query()->create([
                    'customer_id' => $customerId, 'idempotency_digest' => $digest, 'idempotency_key_fingerprint' => $activeKeyFingerprint, 'currency' => $currency,
                    'amount_minor' => $amountMinor, 'remaining_minor' => $amountMinor, 'status' => PaymentRequestStatus::Pending,
                    'expires_at' => $now->addDays($this->expiryDays()),
                ]);
            }, attempts: 3);
        } catch (QueryException $exception) {
            if (! $this->isUniqueViolation($exception)) {
                throw $exception;
            }

            return DB::transaction(function () use ($customerId, $digests, $amountMinor, $currency, $exception): PaymentRequest {
                $replay = PaymentRequest::query()->where('customer_id', $customerId)->whereIn('idempotency_digest', array_values($digests))->lockForUpdate()->first();
                if ($replay === null) {
                    throw $exception;
                }

                return $this->replayOrConflict($this->expireIfDue($replay), $amountMinor, $currency);
            });
        }
    }

    private function expiryDays(): int
    {
        $days = config('payment_requests.pending_expiry_days');

        return is_int($days) && $days >= 30 ? $days : 90;
    }

    private function isOpaqueKey(string $key): bool
    {
        return trim($key) !== '' && mb_strlen($key) <= 255 && preg_match('/[\x00-\x1F\x7F]/', $key) !== 1;
    }

    private function replayOrConflict(PaymentRequest $request, int $amountMinor, string $currency): PaymentRequest
    {
        if ((int) $request->amount_minor !== $amountMinor || $request->currency !== $currency) {
            throw new InvalidArgumentException('Payment request idempotency conflict.');
        }

        return $request;
    }

    private function expireIfDue(PaymentRequest $request): PaymentRequest
    {
        if ($request->getRawOriginal('status') === PaymentRequestStatus::Pending->value
            && CarbonImmutable::parse($request->expires_at)->lessThanOrEqualTo(CarbonImmutable::now())) {
            $request->status = PaymentRequestStatus::Expired->value;
            $request->save();
        }

        return $request;
    }

    /**
     * @param  array<string, string>  $keyRing
     * @return array<string, string>
     */
    private function idempotencyDigests(string $customerId, string $key, array $keyRing): array
    {
        $payload = json_encode([
            'version' => 'openpay.payment-request.idempotency.v1',
            'customer_id' => $customerId,
            'key' => $key,
        ], JSON_THROW_ON_ERROR);
        $digests = [];
        foreach ($keyRing as $keyId => $secret) {
            $digests[$keyId] = hash_hmac('sha256', $payload, $secret);
        }

        return $digests;
    }

    private function activeKeyId(): string
    {
        $configured = config('payment_requests.idempotency_active_key_id');

        return is_string($configured) && $configured !== '' ? $configured : 'v1';
    }

    private function keyFingerprint(string $secret): string
    {
        return hash_hmac('sha256', 'openpay.payment-request.idempotency-key-fingerprint.v1', $secret);
    }

    /** @param list<string> $configuredKeyFingerprints */
    private function assertPersistedKeyFingerprintsConfigured(string $customerId, array $configuredKeyFingerprints): void
    {
        $unconfiguredFingerprintExists = PaymentRequest::query()
            ->where('customer_id', $customerId)
            ->whereNotIn('idempotency_key_fingerprint', $configuredKeyFingerprints)
            ->exists();
        if ($unconfiguredFingerprintExists) {
            throw new LogicException('Payment-request idempotency key ring is missing persisted key material.');
        }
    }

    /** @return array<string, string> */
    private function keyRing(): array
    {
        $configured = config('payment_requests.idempotency_keys');
        if (is_string($configured) && $configured !== '') {
            try {
                $configured = json_decode($configured, true, 512, JSON_THROW_ON_ERROR);
            } catch (\JsonException) {
                throw new LogicException('Payment-request idempotency key ring is not configured.');
            }
        }
        if ($configured === null || $configured === '' || $configured === []) {
            $configured = ['v1' => config('payment_requests.idempotency_key')];
        }
        if (! is_array($configured)) {
            throw new LogicException('Payment-request idempotency key ring is not configured.');
        }

        $ring = [];
        foreach ($configured as $keyId => $secret) {
            $keyId = (string) $keyId;
            if (preg_match('/^[A-Za-z0-9._-]{1,64}$/D', $keyId) !== 1 || ! is_string($secret) || mb_strlen($secret) < 32) {
                throw new LogicException('Payment-request idempotency key ring is not configured.');
            }
            $ring[$keyId] = $secret;
        }
        if (! array_key_exists($this->activeKeyId(), $ring)) {
            throw new LogicException('Payment-request idempotency key ring is not configured.');
        }

        return $ring;
    }

    private function isUniqueViolation(QueryException $exception): bool
    {
        return in_array($exception->getCode(), ['23000', '23505'], true);
    }
}
