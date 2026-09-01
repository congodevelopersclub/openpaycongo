<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\Models\Organization;
use App\Models\PairingIntent;
use App\Models\SourceInstallation;
use App\Models\User;
use App\Pairing\ConfirmPairingIntent;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\RateLimiter;
use Tests\TestCase;

final class ConfirmPairingIntentTest extends TestCase
{
    use RefreshDatabase;

    public function test_verified_organization_operator_reads_sas_then_activates_once_with_one_scoped_mobile_token(): void
    {
        [$operator, $intent] = $this->pendingConfirmation();
        $receiveKey = $intent->server_receive_key;
        $sendKey = $intent->server_send_key;

        $this->asVerified($operator)
            ->getJson('/v1/pairing/intents/'.$intent->intent_id.'/confirmation')
            ->assertOk()
            ->assertHeader('Cache-Control', 'no-store, private')
            ->assertJsonPath('status', 'pending_confirmation')
            ->assertJsonPath('expires_at', $intent->expires_at->utc()->format('Y-m-d\TH:i:s\Z'))
            ->assertJsonStructure(['status', 'expires_at', 'short_authentication_code']);

        $requestId = $this->base64Url(random_bytes(16));
        $payload = ['request_id' => $requestId, 'decision' => 'codes_match', 'reason' => 'codes_compared_match'];

        $response = $this->asVerified($operator)
            ->postJson('/v1/pairing/intents/'.$intent->intent_id.'/confirmation', $payload)
            ->assertOk()
            ->assertHeader('Cache-Control', 'no-store, private')
            ->assertExactJson(['status' => 'active']);

        $installation = SourceInstallation::query()->sole();
        self::assertSame($operator->organization_id, $installation->organization_id);
        self::assertSame($receiveKey, $installation->mobile_receive_key);
        self::assertSame($sendKey, $installation->mobile_send_key);
        self::assertSame(0, $installation->mobile_replay_counter);
        self::assertSame(1, $installation->tokens()->count());
        self::assertSame(['mobile:deposits:write', 'mobile:sync:read', 'mobile:sync:write'], $installation->tokens()->sole()->abilities);

        $consumed = $intent->fresh();
        self::assertSame('active', $consumed->state);
        self::assertNull($consumed->server_receive_key);
        self::assertNull($consumed->server_send_key);
        self::assertNull($consumed->short_authentication_code);
        self::assertNull($consumed->completion_request_digest);
        self::assertNull($consumed->completion_result);

        $this->app->forgetInstance(ConfirmPairingIntent::class);
        $this->asVerified($operator)
            ->postJson('/v1/pairing/intents/'.$intent->intent_id.'/confirmation', $payload)
            ->assertOk()
            ->assertExactJson($response->json());
        self::assertSame(1, SourceInstallation::query()->count());
        self::assertSame(1, $installation->fresh()->tokens()->count());

        $this->asVerified($operator)
            ->postJson('/v1/pairing/intents/'.$intent->intent_id.'/confirmation', [
                'request_id' => $requestId,
                'decision' => 'codes_mismatch',
                'reason' => 'codes_compared_mismatch',
            ])
            ->assertConflict();
    }

    public function test_first_mismatch_wins_and_scrubs_pending_material_without_installation_or_token(): void
    {
        [$operator, $intent] = $this->pendingConfirmation();

        $this->asVerified($operator)
            ->postJson('/v1/pairing/intents/'.$intent->intent_id.'/confirmation', [
                'request_id' => $this->base64Url(random_bytes(16)),
                'decision' => 'codes_mismatch',
                'reason' => 'codes_compared_mismatch',
            ])
            ->assertOk()
            ->assertExactJson(['status' => 'revoked']);

        $terminal = $intent->fresh();
        self::assertSame('revoked', $terminal->state);
        self::assertSame('', $terminal->protected_server_private_material);
        self::assertNull($terminal->pairing_secret_digest);
        self::assertNull($terminal->server_receive_key);
        self::assertNull($terminal->server_send_key);
        self::assertNull($terminal->short_authentication_code);
        self::assertNull($terminal->completion_request_digest);
        self::assertNull($terminal->completion_result);
        self::assertDatabaseCount('source_installations', 0);
        self::assertDatabaseCount('personal_access_tokens', 0);
        $this->getJson('/v1/pairing/intents/'.$intent->intent_id.'/activation')
            ->assertNotFound()
            ->assertJsonPath('code', 'pairing_unavailable');
    }

    public function test_matching_codes_deliver_one_opaque_activation_envelope_to_the_paired_phone(): void
    {
        [$operator, $intent] = $this->pendingConfirmation();
        $phoneReceiveKey = $intent->server_send_key;

        $this->asVerified($operator)
            ->postJson('/v1/pairing/intents/'.$intent->intent_id.'/confirmation', [
                'request_id' => $this->base64Url(random_bytes(16)),
                'decision' => 'codes_match',
                'reason' => 'codes_compared_match',
            ])
            ->assertOk()
            ->assertExactJson(['status' => 'active']);

        $first = $this->getJson('/v1/pairing/intents/'.$intent->intent_id.'/activation')
            ->assertOk()
            ->assertHeader('Cache-Control', 'no-store, private')
            ->assertJsonPath('version', 2)
            ->assertJsonStructure(['version', 'nonce', 'ciphertext']);
        $this->getJson('/v1/pairing/intents/'.$intent->intent_id.'/activation')
            ->assertOk()
            ->assertExactJson($first->json());

        $nonce = $this->decodeBase64Url((string) $first->json('nonce'));
        $ciphertext = $this->decodeBase64Url((string) $first->json('ciphertext'));
        $plaintext = sodium_crypto_aead_xchacha20poly1305_ietf_decrypt(
            $ciphertext,
            $this->activationAad($intent->intent_id_bytes),
            $nonce,
            $phoneReceiveKey,
        );

        self::assertIsString($plaintext);
        /** @var array{version: int, installation_id: string, bearer_token: string} $credential */
        $credential = json_decode($plaintext, true, 3, JSON_THROW_ON_ERROR);
        $installation = SourceInstallation::query()->sole();
        self::assertSame(2, $credential['version']);
        self::assertSame($installation->getKey(), $credential['installation_id']);
        self::assertMatchesRegularExpression('/^[0-9]+\|[A-Za-z0-9]+$/', $credential['bearer_token']);
        [, $tokenValue] = explode('|', $credential['bearer_token'], 2);
        self::assertTrue(hash_equals($installation->tokens()->sole()->token, hash('sha256', $tokenValue)));
    }

    public function test_activation_retrieval_is_limited_without_revealing_which_intent_exists(): void
    {
        $limitKey = 'pairing.activation:'.hash('sha256', '127.0.0.1');
        RateLimiter::clear($limitKey);

        try {
            foreach (range(1, 10) as $attempt) {
                $this->getJson('/v1/pairing/intents/'.$this->base64Url(random_bytes(16)).'/activation')
                    ->assertNotFound()
                    ->assertJsonPath('code', 'pairing_unavailable');
            }

            $this->getJson('/v1/pairing/intents/'.$this->base64Url(random_bytes(16)).'/activation')
                ->assertTooManyRequests()
                ->assertHeader('Retry-After')
                ->assertJsonPath('code', 'pairing_rate_limited');
        } finally {
            RateLimiter::clear($limitKey);
        }
    }

    public function test_confirmation_is_organization_scoped_and_expiry_scrubs_without_activation(): void
    {
        [$operator, $intent] = $this->pendingConfirmation(expiresAt: now()->subSecond());
        $other = User::factory()->create([
            'organization_id' => Organization::query()->create()->getKey(),
            'is_financial_operator' => true,
            'two_factor_confirmed_at' => now(),
            'recovery_codes_confirmed_at' => now(),
        ]);

        $this->asVerified($other)
            ->getJson('/v1/pairing/intents/'.$intent->intent_id.'/confirmation')
            ->assertNotFound();

        $this->asVerified($operator)
            ->getJson('/v1/pairing/intents/'.$intent->intent_id.'/confirmation')
            ->assertOk()
            ->assertExactJson(['status' => 'expired', 'expires_at' => $intent->expires_at->utc()->format('Y-m-d\TH:i:s\Z')]);

        $this->asVerified($operator)
            ->postJson('/v1/pairing/intents/'.$intent->intent_id.'/confirmation', [
                'request_id' => $this->base64Url(random_bytes(16)),
                'decision' => 'codes_match',
                'reason' => 'codes_compared_match',
            ])
            ->assertOk()
            ->assertExactJson(['status' => 'expired']);

        $expired = $intent->fresh();
        self::assertSame('expired', $expired->state);
        self::assertNull($expired->server_receive_key);
        self::assertNull($expired->server_send_key);
        self::assertNull($expired->short_authentication_code);
        self::assertDatabaseCount('source_installations', 0);
        self::assertDatabaseCount('personal_access_tokens', 0);
    }

    /** @return array{User, PairingIntent} */
    private function pendingConfirmation(?\DateTimeInterface $expiresAt = null): array
    {
        $organization = Organization::query()->create();
        $operator = User::factory()->create([
            'organization_id' => $organization->getKey(),
            'is_financial_operator' => true,
            'two_factor_confirmed_at' => now(),
            'recovery_codes_confirmed_at' => now(),
        ]);
        $intentBytes = random_bytes(16);

        return [$operator, PairingIntent::query()->create([
            'organization_id' => $organization->getKey(),
            'intent_id' => $this->base64Url($intentBytes),
            'intent_id_bytes' => $intentBytes,
            'state' => 'pending_confirmation',
            'expires_at' => $expiresAt ?? now()->addMinute(),
            'protected_server_private_material' => '',
            'server_receive_key' => random_bytes(32),
            'server_send_key' => random_bytes(32),
            'short_authentication_code' => str_pad((string) random_int(0, 999999), 6, '0', STR_PAD_LEFT),
        ])];
    }

    private function base64Url(string $value): string
    {
        return rtrim(strtr(base64_encode($value), '+/', '-_'), '=');
    }

    private function decodeBase64Url(string $value): string
    {
        $decoded = base64_decode(strtr($value, '-_', '+/').str_repeat('=', (4 - strlen($value) % 4) % 4), true);

        self::assertIsString($decoded);

        return $decoded;
    }

    private function activationAad(string $intentId): string
    {
        return pack('n', 43).'openpaycongo/pairing/activation-response/v2'.pack('n', 16).$intentId;
    }

    private function asVerified(User $operator): self
    {
        return $this->actingAs($operator)->withSession([
            'financial_operator_mfa.user_id' => $operator->getAuthIdentifier(),
        ]);
    }
}
