<?php

declare(strict_types=1);

namespace App\Pairing;

use App\Models\PairingCompletionReservation;
use App\Models\PairingIntent;
use Carbon\CarbonImmutable;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use Throwable;

/**
 * Durable pre-crypto completion lifecycle.
 *
 * Caller computes the exact request digest without storing request/proof data.
 * Later cryptographic work must settle the returned reservation exactly once.
 */
final readonly class ReservePairingCompletion
{
    private const int RESERVATION_LEASE_SECONDS = 30;

    public function __construct(private int $invalidProofAttemptBudget = 3)
    {
        if ($invalidProofAttemptBudget < 1 || $invalidProofAttemptBudget > 5) {
            throw new \InvalidArgumentException('Invalid pairing proof attempt budget.');
        }
    }

    public function reserve(string $intentIdBytes, string $requestDigest): PairingCompletionReservationResult
    {
        if (strlen($intentIdBytes) !== 16 || strlen($requestDigest) !== 32) {
            return PairingCompletionReservationResult::unavailable();
        }

        try {
            return DB::transaction(function () use ($intentIdBytes, $requestDigest): PairingCompletionReservationResult {
                $now = CarbonImmutable::now('UTC');
                $intent = PairingIntent::query()->lockForUpdate()
                    ->where('intent_id_bytes', $intentIdBytes)
                    ->first();
                if (! $intent instanceof PairingIntent) {
                    return PairingCompletionReservationResult::unavailable();
                }
                if ($intent->completion_request_digest !== null
                    && hash_equals($intent->completion_request_digest, $requestDigest)
                    && is_string($intent->completion_result)) {
                    return PairingCompletionReservationResult::replayed($intent->completion_result);
                }
                if ($intent->state !== 'pending') {
                    return PairingCompletionReservationResult::unavailable();
                }
                if (CarbonImmutable::parse($intent->expires_at)->lessThanOrEqualTo($now)) {
                    $this->terminal($intent, 'expired');

                    return PairingCompletionReservationResult::unavailable();
                }
                if ((int) $intent->invalid_proof_attempts >= $this->invalidProofAttemptBudget) {
                    $this->terminal($intent, 'exhausted');

                    return PairingCompletionReservationResult::unavailable();
                }
                $this->expireLeases($intent, $now);
                if (PairingCompletionReservation::query()
                    ->where('pairing_intent_id', $intent->id)
                    ->where('state', 'reserved')
                    ->exists()) {
                    return PairingCompletionReservationResult::unavailable();
                }

                $reservation = PairingCompletionReservation::query()->create([
                    'id' => (string) Str::uuid(),
                    'pairing_intent_id' => $intent->id,
                    'request_digest' => $requestDigest,
                    'state' => 'reserved',
                    'lease_expires_at' => $now->addSeconds(self::RESERVATION_LEASE_SECONDS),
                ]);

                return PairingCompletionReservationResult::reserved($reservation->id);
            });
        } catch (Throwable) {
            return PairingCompletionReservationResult::unavailable();
        }
    }

    public function releaseRetryable(string $reservationId): PairingCompletionSettlementOutcome
    {
        return $this->settle($reservationId, static function (PairingIntent $intent, PairingCompletionReservation $reservation): void {
            $reservation->forceFill(['state' => 'released'])->save();
        });
    }

    public function rejectInvalidProof(string $reservationId): PairingCompletionSettlementOutcome
    {
        return $this->settle($reservationId, function (PairingIntent $intent, PairingCompletionReservation $reservation): void {
            $attempts = (int) $intent->invalid_proof_attempts + 1;
            $intent->forceFill(['invalid_proof_attempts' => $attempts]);
            if ($attempts >= $this->invalidProofAttemptBudget) {
                $this->terminal($intent, 'exhausted');
            } else {
                $intent->save();
            }
            $reservation->forceFill(['state' => 'invalid'])->save();
        });
    }

    public function commit(string $reservationId, string $opaqueEncryptedResult): PairingCompletionSettlementOutcome
    {
        if ($opaqueEncryptedResult === '' || strlen($opaqueEncryptedResult) > 4096) {
            throw new \InvalidArgumentException('Invalid pairing completion result.');
        }

        return $this->settle($reservationId, static function (PairingIntent $intent, PairingCompletionReservation $reservation) use ($opaqueEncryptedResult): void {
            $intent->forceFill([
                'state' => 'pending_confirmation',
                'completion_request_digest' => $reservation->getRawOriginal('request_digest'),
                'completion_result' => $opaqueEncryptedResult,
                'protected_server_private_material' => '',
            ])->save();
            $reservation->forceFill(['state' => 'committed'])->save();
        });
    }

    private function settle(string $reservationId, callable $settlement): PairingCompletionSettlementOutcome
    {
        if (! Str::isUuid($reservationId)) {
            return PairingCompletionSettlementOutcome::Stale;
        }
        try {
            return DB::transaction(function () use ($reservationId, $settlement): PairingCompletionSettlementOutcome {
                $candidate = PairingCompletionReservation::query()->find($reservationId);
                if (! $candidate instanceof PairingCompletionReservation) {
                    return PairingCompletionSettlementOutcome::Stale;
                }
                $intent = PairingIntent::query()->lockForUpdate()->find($candidate->pairing_intent_id);
                $reservation = PairingCompletionReservation::query()->lockForUpdate()->find($reservationId);
                if (! $intent instanceof PairingIntent || ! $reservation instanceof PairingCompletionReservation
                    || $intent->state !== 'pending' || $reservation->state !== 'reserved') {
                    return PairingCompletionSettlementOutcome::Stale;
                }
                if (CarbonImmutable::parse($reservation->lease_expires_at)->lessThanOrEqualTo(CarbonImmutable::now('UTC'))) {
                    $reservation->forceFill(['state' => 'expired'])->save();

                    return PairingCompletionSettlementOutcome::Stale;
                }
                $settlement($intent, $reservation);

                return PairingCompletionSettlementOutcome::Settled;
            });
        } catch (Throwable) {
            return PairingCompletionSettlementOutcome::Unknown;
        }
    }

    private function expireLeases(PairingIntent $intent, CarbonImmutable $now): void
    {
        PairingCompletionReservation::query()
            ->where('pairing_intent_id', $intent->id)
            ->where('state', 'reserved')
            ->where('lease_expires_at', '<=', $now)
            ->update(['state' => 'expired', 'updated_at' => $now]);
    }

    private function terminal(PairingIntent $intent, string $state): void
    {
        $intent->forceFill([
            'state' => $state,
            'protected_server_private_material' => '',
        ])->save();
    }
}
