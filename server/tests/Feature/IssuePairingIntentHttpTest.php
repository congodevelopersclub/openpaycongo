<?php

namespace Tests\Feature;

use App\Models\Organization;
use App\Models\PairingIntent;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

final class IssuePairingIntentHttpTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        config(['openpay.pairing' => [
            'endpoint' => 'https://pairing.openpay.example/v1/pairing/complete',
            'enrollment_signing_secret' => rtrim(strtr(base64_encode(str_repeat('s', 32)), '+/', '-_'), '='),
            'trust_mode' => 'first_use_requires_sas',
        ]]);
    }

    public function test_authenticated_administrator_issues_only_public_qr_for_own_organization(): void
    {
        $organization = Organization::query()->create();
        $administrator = User::factory()->create();
        $administrator->forceFill([
            'organization_id' => $organization->getKey(),
            'is_financial_operator' => true,
        ])->save();

        $response = $this->actingAs($administrator)->postJson('/v1/pairing/intents', [
            'lifetime_seconds' => 60,
        ]);

        $response->assertCreated()
            ->assertJsonStructure([
                'version', 'endpoint', 'intent_id', 'intent_nonce', 'expires_at', 'algorithms',
                'enrollment_signing_fingerprint', 'enrollment_signing_public_key',
                'server_key_agreement_public_key', 'trust_mode', 'signature',
            ])
            ->assertJsonMissing(['protected_server_private_material']);
        self::assertStringContainsString('no-store', (string) $response->headers->get('cache-control'));
        self::assertCount(11, $response->json());
        self::assertSame($organization->getKey(), PairingIntent::query()->sole()->organization_id);
        self::assertNotSame(
            PairingIntent::query()->sole()->protected_server_private_material,
            $response->getContent(),
        );
    }

    public function test_an_unauthenticated_request_is_rejected_before_an_intent_is_issued(): void
    {
        $this->postJson('/v1/pairing/intents', ['lifetime_seconds' => 60])
            ->assertUnauthorized();

        self::assertDatabaseCount('pairing_intents', 0);
    }

    public function test_a_non_financial_user_is_rejected_before_an_intent_is_issued(): void
    {
        $user = User::factory()->create([
            'organization_id' => Organization::query()->create()->getKey(),
            'is_financial_operator' => false,
        ]);

        $this->actingAs($user)->postJson('/v1/pairing/intents', ['lifetime_seconds' => 60])
            ->assertForbidden();

        self::assertDatabaseCount('pairing_intents', 0);
    }

    public function test_only_a_short_integer_lifetime_is_accepted(): void
    {
        $user = $this->financialOperator();

        foreach ([29, 301, '60', 60.5] as $lifetime) {
            $this->actingAs($user)->postJson('/v1/pairing/intents', ['lifetime_seconds' => $lifetime])
                ->assertUnprocessable()
                ->assertJsonValidationErrors('lifetime_seconds');
        }

        self::assertDatabaseCount('pairing_intents', 0);
    }

    public function test_the_request_cannot_select_an_organization(): void
    {
        $user = $this->financialOperator();

        $this->actingAs($user)->postJson('/v1/pairing/intents', [
            'lifetime_seconds' => 60,
            'organization_id' => Organization::query()->create()->getKey(),
        ])->assertUnprocessable()->assertJsonValidationErrors('organization_id');

        self::assertDatabaseCount('pairing_intents', 0);
    }

    private function financialOperator(): User
    {
        return User::factory()->create([
            'organization_id' => Organization::query()->create()->getKey(),
            'is_financial_operator' => true,
        ]);
    }
}
