<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\Models\SourceInstallation;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Laravel\Sanctum\Sanctum;
use Tests\TestCase;

final class MobileActivationGateTest extends TestCase
{
    use RefreshDatabase;

    public function test_pending_pairing_installation_cannot_read_mobile_identity_after_authentication_and_ability_checks(): void
    {
        $installation = SourceInstallation::query()->create([
            'organization_id' => '00000000-0000-4000-8000-000000000221',
            'installation_digest' => str_repeat('a', 64),
            'pairing_intent_id' => str_repeat('p', 22),
        ]);

        $this->getJson('/mobile/identity')
            ->assertUnauthorized()
            ->assertExactJson(['message' => 'Unauthenticated.']);

        Sanctum::actingAs($installation, ['mobile:sync:write'], 'mobile');

        $this->getJson('/mobile/identity')
            ->assertForbidden()
            ->assertExactJson(['message' => 'Forbidden']);

        Sanctum::actingAs($installation, ['mobile:sync:read'], 'mobile');

        $this->getJson('/mobile/identity')
            ->assertNotFound()
            ->assertExactJson(['code' => 'mobile_envelope_unavailable'])
            ->assertHeader('cache-control', 'no-store, private');
    }

    public function test_pending_pairing_installation_cannot_record_mobile_deposits_after_authentication_and_ability_checks(): void
    {
        $installation = SourceInstallation::query()->create([
            'organization_id' => '00000000-0000-4000-8000-000000000221',
            'installation_digest' => str_repeat('b', 64),
            'installation_lookup_id' => '00000000-0000-4000-8000-000000000222',
            'installation_key_version' => 'v1',
            'pairing_intent_id' => str_repeat('p', 22),
        ]);

        Sanctum::actingAs($installation, ['mobile:deposits:write'], 'mobile');

        $this->postJson('/mobile/deposits', [
            'customer_lookup_identifier' => 'synthetic-customer',
            'provider_reference' => 'synthetic-reference',
            'amount_minor' => 12500,
            'currency' => 'CDF',
            'provider_occurred_at' => '2026-09-06T01:00:00Z',
            'sender_identifier' => 'synthetic-sender',
        ])
            ->assertNotFound()
            ->assertExactJson(['code' => 'mobile_envelope_unavailable'])
            ->assertHeader('cache-control', 'no-store, private');

        self::assertDatabaseCount('deposits', 0);
    }

    public function test_acknowledged_pairing_installation_keeps_mobile_identity_and_deposit_access(): void
    {
        $installation = SourceInstallation::query()->create([
            'organization_id' => '00000000-0000-4000-8000-000000000221',
            'installation_digest' => str_repeat('c', 64),
            'installation_lookup_id' => '00000000-0000-4000-8000-000000000223',
            'installation_key_version' => 'v1',
            'pairing_intent_id' => str_repeat('p', 22),
        ]);
        $installation->forceFill(['activation_acknowledged_at' => now('UTC')])->save();

        Sanctum::actingAs($installation, ['mobile:sync:read'], 'mobile');

        $this->getJson('/mobile/identity')
            ->assertOk()
            ->assertExactJson(['organization_id' => $installation->organization_id]);

        Sanctum::actingAs($installation, ['mobile:deposits:write'], 'mobile');

        $this->postJson('/mobile/deposits', [
            'customer_lookup_identifier' => 'synthetic-customer',
            'provider_reference' => 'synthetic-reference',
            'amount_minor' => 12500,
            'currency' => 'CDF',
            'provider_occurred_at' => '2026-09-06T01:00:00Z',
            'sender_identifier' => 'synthetic-sender',
        ])
            ->assertCreated()
            ->assertExactJson(['outcome' => 'recorded']);

        self::assertDatabaseCount('deposits', 1);
    }
}
