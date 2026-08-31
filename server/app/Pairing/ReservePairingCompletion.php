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
    private const int MAX_IN_FLIGHT = 8;

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
                if (CarbonImmutable::parse($intent->expires_at)->lessThanOrEqualTo(CarbonImmutable::now('UTC'))) {
                    $this->terminal($intent, 'expired');

                    return PairingCompletionReservationResult::unavailable();
                }
                if ((int) $intent->invalid_proof_attempts >= $this->invalidProofAttemptBudget) {
                    $this->terminal($intent, 'exhausted');

                    return PairingCompletionReservationResult::unavailable();
                }
                $reservations = PairingCompletionReservation::query()
                    ->where('pairing_intent_id', $intent->id)
                    ->where('state', 'reserved');
                if ((clone $reservations)->where('request_digest', $requestDigest)->exists()
                    || $reservations->count() >= self::MAX_IN_FLIGHT) {
                    return PairingCompletionReservationResult::unavailable();
                }

                $reservation = PairingCompletionReservation::query()->create([
                    'id' => (string) Str::uuid(),
                    'pairing_intent_id' => $intent->id,
                    'request_digest' => $requestDigest,
                    'state' => 'reserved',
                ]);

                return PairingCompletionReservationResult::reserved($reservation->id);
            });
        } catch (Throwable) {
            return PairingCompletionReservationResult::unavailable();
        }
    }

    public function releaseRetryable(string $reservationId): void
    {
        $this->settle($reservationId, static function (PairingCompletionReservation $reservation): void {
            if ($reservation->state === 'reserved') {
                $reservation->forceFill(['state' => 'released'])->save();
            }
        });
    }

    public function rejectInvalidProof(string $reservationId): void
    {
        $this->settle($reservationId, function (PairingCompletionReservation $reservation): void {
            if ($reservation->state !== 'reserved') {
                return;
            }
            $intent = PairingIntent::query()->lockForUpdate()->find($reservation->pairing_intent_id);
            if (! $intent instanceof PairingIntent || $intent->state !== 'pending') {
                $reservation->forceFill(['state' => 'invalid'])->save();

                return;
            }
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

    public function commit(string $reservationId, string $opaqueEncryptedResult): void
    {
        if ($opaqueEncryptedResult === '' || strlen($opaqueEncryptedResult) > 4096) {
            throw new \InvalidArgumentException('Invalid pairing completion result.');
        }
        $this->settle($reservationId, function (PairingCompletionReservation $reservation) use ($opaqueEncryptedResult): void {
            if ($reservation->state !== 'reserved') {
                return;
            }
            $intent = PairingIntent::query()->lockForUpdate()->find($reservation->pairing_intent_id);
            if (! $intent instanceof PairingIntent || $intent->state !== 'pending') {
                return;
            }
            $intent->forceFill([
                'state' => 'pending_confirmation',
                'completion_request_digest' => $reservation->getRawOriginal('request_digest'),
                'completion_result' => $opaqueEncryptedResult,
                'protected_server_private_material' => '',
            ])->save();
            $reservation->forceFill(['state' => 'committed'])->save();
        });
    }

    private function settle(string $reservationId, callable $settlement): void
    {
        if (! Str::isUuid($reservationId)) {
            return;
        }
        try {
            DB::transaction(function () use ($reservationId, $settlement): void {
                $reservation = PairingCompletionReservation::query()->lockForUpdate()->find($reservationId);
                if ($reservation instanceof PairingCompletionReservation) {
                    $settlement($reservation);
                }
            });
        } catch (Throwable) {
            // Retryable settlement failures are deliberately not exposed here.
        }
    }

    private function terminal(PairingIntent $intent, string $state): void
    {
        $intent->forceFill([
            'state' => $state,
            'protected_server_private_material' => '',
        ])->save();
    }
}
