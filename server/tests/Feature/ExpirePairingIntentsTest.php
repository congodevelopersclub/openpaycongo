<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\Models\Organization;
use App\Models\PairingIntent;
use App\Pairing\ExpirePairingIntents;
use Carbon\CarbonImmutable;
use DateTimeInterface;
use Illuminate\Console\Scheduling\Schedule;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

final class ExpirePairingIntentsTest extends TestCase
{
    use RefreshDatabase;

    public function test_action_locks_and_expires_only_due_pending_states_while_destroying_temporary_material(): void
    {
        $now = CarbonImmutable::parse('2026-09-01 12:00:00 UTC');
        CarbonImmutable::setTestNow($now);

        try {
            $pending = $this->intent('pending', $now->subSecond());
            $confirming = $this->intent('pending_confirmation', $now);
            $future = $this->intent('pending', $now->addSecond());
            $terminal = $this->intent('revoked', $now->subSecond());

            self::assertSame(2, app(ExpirePairingIntents::class)->execute());

            $this->assertDestroyed($pending);
            $this->assertDestroyed($confirming);
            self::assertSame('pending', $future->fresh()->state);
            self::assertSame('revoked', $terminal->fresh()->state);
        } finally {
            CarbonImmutable::setTestNow();
        }
    }

    public function test_command_runs_cleanup_and_schedule_is_bounded_every_minute_without_overlap(): void
    {
        $this->intent('pending', now()->subSecond());

        $this->artisan('pairing:expire-intents')
            ->expectsOutput('Expired 1 pairing intent(s).')
            ->assertExitCode(0);

        $event = collect(app(Schedule::class)->events())
            ->first(fn ($event): bool => str_contains($event->command, 'pairing:expire-intents'));
        self::assertNotNull($event);
        self::assertSame('* * * * *', $event->expression);
        self::assertTrue($event->withoutOverlapping);
    }

    public function test_action_processes_at_most_one_bounded_page_per_run(): void
    {
        $now = CarbonImmutable::parse('2026-09-01 12:00:00 UTC');
        CarbonImmutable::setTestNow($now);

        try {
            for ($index = 0; $index <= ExpirePairingIntents::MAX_PER_RUN; $index++) {
                $this->intent('pending', $now->subSecond());
            }

            self::assertSame(ExpirePairingIntents::MAX_PER_RUN, app(ExpirePairingIntents::class)->execute());
            self::assertSame(ExpirePairingIntents::MAX_PER_RUN, PairingIntent::query()->where('state', 'expired')->count());
            self::assertSame(1, PairingIntent::query()->where('state', 'pending')->count());
        } finally {
            CarbonImmutable::setTestNow();
        }
    }

    private function intent(string $state, DateTimeInterface $expiresAt): PairingIntent
    {
        $organization = Organization::query()->create();

        $intentIdBytes = random_bytes(16);

        return PairingIntent::query()->create([
            'organization_id' => $organization->id,
            'intent_id' => rtrim(strtr(base64_encode($intentIdBytes), '+/', '-_'), '='),
            'intent_id_bytes' => $intentIdBytes,
            'state' => $state,
            'expires_at' => $expiresAt,
            'protected_server_private_material' => 'encrypted-seed',
            'pairing_secret_digest' => hash('sha256', 'secret'),
            'server_receive_key' => random_bytes(32),
            'server_send_key' => random_bytes(32),
            'short_authentication_code' => '123456',
            'completion_request_digest' => hash('sha256', 'request'),
            'completion_result' => '{"ciphertext":"opaque"}',
        ]);
    }

    private function assertDestroyed(PairingIntent $intent): void
    {
        $expired = $intent->fresh();

        self::assertSame('expired', $expired->state);
        self::assertSame('', $expired->protected_server_private_material);
        self::assertNull($expired->pairing_secret_digest);
        self::assertNull($expired->server_receive_key);
        self::assertNull($expired->server_send_key);
        self::assertNull($expired->short_authentication_code);
        self::assertNull($expired->completion_request_digest);
        self::assertNull($expired->completion_result);
    }
}
