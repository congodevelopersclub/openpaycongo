<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\Models\Deposit;
use App\Models\Organization;
use App\Models\PairedInstallationRevocationAudit;
use App\Models\SourceInstallation;
use App\Models\User;
use App\Pairing\RevokePairedInstallation;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Laravel\Sanctum\Sanctum;
use Tests\TestCase;

final class RevokePairedInstallationTest extends TestCase
{
    use RefreshDatabase;

    public function test_verified_operator_revocation_deletes_credentials_scrubs_keys_and_preserves_deposits(): void
    {
        $organization = Organization::query()->create();
        $operator = User::factory()->create([
            'organization_id' => $organization->getKey(),
            'is_financial_operator' => true,
            'two_factor_confirmed_at' => now(),
            'recovery_codes_confirmed_at' => now(),
        ]);
        $intentId = $this->intentId();
        $installation = $this->pairedInstallation($organization->getKey(), $intentId);
        $oldBearer = $installation->createToken('paired-mobile-installation', ['mobile:deposits:write', 'mobile:sync:read'])->plainTextToken;

        Sanctum::actingAs($installation, ['mobile:deposits:write'], 'mobile');
        $this->postJson('/mobile/deposits', $this->depositPayload())
            ->assertCreated()
            ->assertExactJson(['outcome' => 'recorded']);
        self::assertDatabaseCount('deposits', 1);

        app(RevokePairedInstallation::class)->revoke($operator, $installation->getKey());

        $revoked = $installation->fresh();
        self::assertNotNull($revoked->revoked_at);
        self::assertNull($revoked->mobile_receive_key);
        self::assertNull($revoked->mobile_send_key);
        self::assertNull($revoked->activation_nonce);
        self::assertNull($revoked->activation_ciphertext);
        self::assertSame(0, $revoked->tokens()->count());
        self::assertSame(1, Deposit::query()->count());

        $audit = PairedInstallationRevocationAudit::query()->sole();
        self::assertSame($organization->getKey(), $audit->organization_id);
        self::assertSame($installation->getKey(), $audit->source_installation_id);
        self::assertSame($operator->getKey(), $audit->actor_user_id);
        self::assertSame('revoked', $audit->action);
        self::assertSame([
            'id', 'organization_id', 'source_installation_id', 'actor_user_id', 'actor_user_identifier', 'action', 'created_at',
        ], array_keys($audit->getAttributes()));

        app('auth')->forgetGuards();
        $this->withToken($oldBearer)
            ->getJson('/mobile/identity')
            ->assertUnauthorized()
            ->assertExactJson(['message' => 'Unauthenticated.']);

        Sanctum::actingAs($revoked, ['mobile:sync:read'], 'mobile');
        $this->getJson('/mobile/identity')
            ->assertNotFound()
            ->assertExactJson(['code' => 'mobile_envelope_unavailable']);
        $this->getJson('/v1/pairing/intents/'.$intentId.'/activation')
            ->assertNotFound()
            ->assertJsonPath('code', 'pairing_unavailable');
    }

    private function pairedInstallation(string $organizationId, string $intentId): SourceInstallation
    {
        $installation = SourceInstallation::query()->create([
            'organization_id' => $organizationId,
            'installation_digest' => hash('sha256', $intentId),
            'installation_lookup_id' => (string) str()->uuid(),
            'installation_key_version' => 'pairing-v2',
            'mobile_receive_key' => random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES),
            'mobile_send_key' => random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES),
        ]);

        $installation->forceFill([
            'pairing_intent_id' => $intentId,
            'activation_nonce' => random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES),
            'activation_ciphertext' => random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_ABYTES),
            'activation_acknowledged_at' => now('UTC'),
        ])->save();

        return $installation;
    }

    /** @return array<string, int|string> */
    private function depositPayload(): array
    {
        return [
            'customer_lookup_identifier' => 'revocation-customer',
            'provider_reference' => 'revocation-reference',
            'amount_minor' => 12500,
            'currency' => 'CDF',
            'provider_occurred_at' => '2026-09-06T01:00:00Z',
        ];
    }

    private function intentId(): string
    {
        return rtrim(strtr(base64_encode(random_bytes(16)), '+/', '-_'), '=');
    }
}
