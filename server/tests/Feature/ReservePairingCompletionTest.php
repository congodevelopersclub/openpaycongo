<?php

namespace Tests\Feature;

use App\Models\Organization;
use App\Models\PairingCompletionReservation;
use App\Models\PairingIntent;
use App\Pairing\PairingCompletionReservationOutcome;
use App\Pairing\ReservePairingCompletion;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

final class ReservePairingCompletionTest extends TestCase
{
    use RefreshDatabase;

    public function test_committed_exact_digest_replays_its_durable_opaque_result_without_a_new_reservation(): void
    {
        $intent = $this->intent();
        $action = new ReservePairingCompletion(3);
        $digest = $this->digest('exact-request');

        $reserved = $action->reserve($intent->intent_id_bytes, $digest);
        $action->commit((string) $reserved->reservationId(), 'encrypted-result-v1');
        $replayed = $action->reserve($intent->intent_id_bytes, $digest);

        $this->assertSame(PairingCompletionReservationOutcome::Replayed, $replayed->outcome());
        $this->assertSame('encrypted-result-v1', $replayed->cachedResult());
        $this->assertStringNotContainsString('encrypted-result-v1', json_encode($replayed, JSON_THROW_ON_ERROR));
        $this->assertDatabaseCount('pairing_completion_reservations', 1);
        $this->assertSame('pending_confirmation', $intent->fresh()->state);
        $this->assertSame('', $intent->fresh()->getRawOriginal('protected_server_private_material'));
    }

    public function test_invalid_proofs_consume_only_the_bounded_budget_then_terminally_clear_intent_material(): void
    {
        $intent = $this->intent();
        $action = new ReservePairingCompletion(2);

        foreach (['first', 'second'] as $request) {
            $reserved = $action->reserve($intent->intent_id_bytes, $this->digest($request));
            $this->assertSame(PairingCompletionReservationOutcome::Reserved, $reserved->outcome());
            $action->rejectInvalidProof((string) $reserved->reservationId());
        }

        $reloaded = $intent->fresh();
        $this->assertSame(2, $reloaded->invalid_proof_attempts);
        $this->assertSame('exhausted', $reloaded->state);
        $this->assertSame('', $reloaded->getRawOriginal('protected_server_private_material'));
        $this->assertSame(PairingCompletionReservationOutcome::Unavailable, $action->reserve($intent->intent_id_bytes, $this->digest('later'))->outcome());
    }

    public function test_reservation_allows_eight_distinct_concurrent_workers_but_denies_a_ninth_and_duplicate_inflight_digest(): void
    {
        $intent = $this->intent();
        $action = new ReservePairingCompletion(3);

        for ($index = 0; $index < 8; $index++) {
            $this->assertSame(PairingCompletionReservationOutcome::Reserved, $action->reserve($intent->intent_id_bytes, $this->digest('request-'.$index))->outcome());
        }
        $this->assertSame(PairingCompletionReservationOutcome::Unavailable, $action->reserve($intent->intent_id_bytes, $this->digest('request-0'))->outcome());
        $this->assertSame(PairingCompletionReservationOutcome::Unavailable, $action->reserve($intent->intent_id_bytes, $this->digest('ninth'))->outcome());
        $this->assertSame(8, PairingCompletionReservation::query()->where('state', 'reserved')->count());
    }

    public function test_retryable_fault_release_is_idempotent_and_does_not_consume_an_invalid_attempt(): void
    {
        $intent = $this->intent();
        $action = new ReservePairingCompletion(3);
        $digest = $this->digest('retryable');
        $reserved = $action->reserve($intent->intent_id_bytes, $digest);

        $action->releaseRetryable((string) $reserved->reservationId());
        $action->releaseRetryable((string) $reserved->reservationId());
        $retried = $action->reserve($intent->intent_id_bytes, $digest);
        $action->releaseRetryable((string) $retried->reservationId());

        $this->assertSame(PairingCompletionReservationOutcome::Reserved, $retried->outcome());
        $this->assertSame(0, $intent->fresh()->invalid_proof_attempts);
        $this->assertSame('pending', $intent->fresh()->state);
        $this->assertSame('released', PairingCompletionReservation::query()->find($reserved->reservationId())->state);
        $this->assertSame('released', PairingCompletionReservation::query()->find($retried->reservationId())->state);
    }

    private function intent(): PairingIntent
    {
        $organization = Organization::query()->create();
        $bytes = random_bytes(16);

        return PairingIntent::query()->create([
            'organization_id' => $organization->id,
            'intent_id' => rtrim(strtr(base64_encode($bytes), '+/', '-_'), '='),
            'intent_id_bytes' => $bytes,
            'state' => 'pending',
            'expires_at' => now()->addMinute(),
            'protected_server_private_material' => 'protected-server-material',
        ]);
    }

    private function digest(string $value): string
    {
        return hash('sha256', $value, true);
    }
}
