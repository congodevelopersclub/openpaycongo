<?php

namespace Tests\Feature;

use App\Events\ProviderDepositRecorded;
use App\Models\Deposit;
use App\Models\SourceInstallation;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Event;
use Laravel\Sanctum\Sanctum;
use Tests\TestCase;

final class MobileDepositIngressTest extends TestCase
{
    use RefreshDatabase;

    public function test_authenticated_installation_records_replays_and_conflicts_without_request_tenant_authority(): void
    {
        $recordedDepositIds = [];
        Event::listen(ProviderDepositRecorded::class, static function (ProviderDepositRecorded $event) use (&$recordedDepositIds): void {
            $recordedDepositIds[] = $event->depositId;
        });
        $installation = SourceInstallation::query()->create([
            'organization_id' => '00000000-0000-4000-8000-000000000001',
            'installation_digest' => str_repeat('a', 64),
            'installation_lookup_id' => '00000000-0000-4000-8000-000000000002',
            'installation_key_version' => 'v1',
        ]);
        $payload = [
            'customer_lookup_identifier' => 'customer-001',
            'provider_reference' => 'synthetic-reference-001',
            'amount_minor' => 12500,
            'currency' => 'CDF',
            'provider_occurred_at' => '2026-08-31T01:00:00Z',
            'sender_identifier' => 'synthetic-provider',
        ];

        $this->postJson('/mobile/deposits', $payload)->assertUnauthorized();
        Sanctum::actingAs($installation, ['mobile:sync:write'], 'mobile');
        $this->postJson('/mobile/deposits', $payload)->assertForbidden();
        Sanctum::actingAs($installation, ['mobile:deposits:write'], 'mobile');

        $this->postJson('/mobile/deposits', [...$payload, 'organization_id' => '00000000-0000-4000-8000-000000000099'])
            ->assertUnprocessable();
        self::assertDatabaseCount('deposits', 0);

        $this->postJson('/mobile/deposits', $payload)
            ->assertCreated()
            ->assertExactJson(['outcome' => 'recorded'])
            ->assertHeader('cache-control', 'no-store, private');
        $this->postJson('/mobile/deposits', $payload)
            ->assertOk()
            ->assertExactJson(['outcome' => 'replayed']);
        $this->postJson('/mobile/deposits', [...$payload, 'amount_minor' => 12600])
            ->assertConflict()
            ->assertExactJson(['outcome' => 'conflict']);

        self::assertDatabaseCount('deposits', 1);
        self::assertSame($installation->id, Deposit::query()->sole()->source_installation_id);
        self::assertSame($installation->organization_id, Deposit::query()->sole()->organization_id);
        self::assertSame([Deposit::query()->sole()->id], $recordedDepositIds);
    }

    public function test_invalid_provider_occurrence_is_rejected_before_deposit_recording(): void
    {
        $installation = SourceInstallation::query()->create([
            'organization_id' => '00000000-0000-4000-8000-000000000001',
            'installation_digest' => str_repeat('b', 64),
        ]);
        Sanctum::actingAs($installation, ['mobile:deposits:write'], 'mobile');

        foreach (['2026-02-30T01:00:00Z', '2026-08-31T01:00:00+99:00'] as $providerOccurredAt) {
            $this->postJson('/mobile/deposits', [
                'customer_lookup_identifier' => 'customer-001',
                'provider_reference' => 'synthetic-reference-001',
                'amount_minor' => 12500,
                'currency' => 'CDF',
                'provider_occurred_at' => $providerOccurredAt,
            ])->assertUnprocessable()
                ->assertJsonValidationErrors('provider_occurred_at');
        }

        self::assertDatabaseCount('deposits', 0);
    }
}
