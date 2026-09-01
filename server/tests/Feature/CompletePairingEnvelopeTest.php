<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\Models\Organization;
use App\Models\PairingIntent;
use App\Pairing\KeyProtector;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Testing\TestResponse;
use Tests\TestCase;

final class CompletePairingEnvelopeTest extends TestCase
{
    use RefreshDatabase;

    public function test_valid_kx_envelope_creates_pending_confirmation_without_persisting_pairing_private_material(): void
    {
        $organization = Organization::query()->create();
        $seed = random_bytes(SODIUM_CRYPTO_KX_SEEDBYTES);
        $server = sodium_crypto_kx_seed_keypair($seed);
        $client = sodium_crypto_kx_keypair();
        $secret = random_bytes(32);
        $intentBytes = random_bytes(16);
        $intent = PairingIntent::query()->create([
            'organization_id' => $organization->getKey(),
            'intent_id' => rtrim(strtr(base64_encode($intentBytes), '+/', '-_'), '='),
            'intent_id_bytes' => $intentBytes,
            'state' => 'pending',
            'expires_at' => now()->addMinute(),
            'protected_server_private_material' => app(KeyProtector::class)->protect(
                $seed,
                'openpaycongo/pairing/intent-server-private-material/v1/'.$organization->getKey().'/'.rtrim(strtr(base64_encode($intentBytes), '+/', '-_'), '='),
            ),
            'pairing_secret_digest' => hash('sha256', $secret),
            'server_key_agreement_public_key' => $this->base64Url(sodium_crypto_kx_publickey($server)),
        ]);
        // Server receive key is client's transmit key. Test derives it through
        // the same audited crypto_kx contract, not scalar multiplication.
        $keys = sodium_crypto_kx_server_session_keys($server, sodium_crypto_kx_publickey($client));
        $nonce = random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES);
        $ciphertext = sodium_crypto_aead_xchacha20poly1305_ietf_encrypt(
            $secret,
            $this->aad($intent->intent_id_bytes, sodium_crypto_kx_publickey($client)),
            $nonce,
            $keys[0],
        );

        $payload = [
            'intent_id' => $intent->intent_id,
            'client_public_key' => $this->base64Url(sodium_crypto_kx_publickey($client)),
            'nonce' => $this->base64Url($nonce),
            'ciphertext' => $this->base64Url($ciphertext),
        ];
        $tampered = $ciphertext;
        $tampered[0] = chr(ord($tampered[0]) ^ 1);
        $this->assertPairingUnavailable(
            $this->postJson('/v1/pairing/complete', [...$payload, 'ciphertext' => $this->base64Url($tampered)]),
        );

        foreach ([substr($ciphertext, 0, -1), $ciphertext.chr(0)] as $wrongLengthCiphertext) {
            $this->assertPairingUnavailable(
                $this->postJson('/v1/pairing/complete', [...$payload, 'ciphertext' => $this->base64Url($wrongLengthCiphertext)]),
            );
        }

        $wrongNonce = random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES);
        $wrongSecret = sodium_crypto_aead_xchacha20poly1305_ietf_encrypt(
            random_bytes(32), $this->aad($intent->intent_id_bytes, sodium_crypto_kx_publickey($client)), $wrongNonce, $keys[0],
        );
        $this->assertPairingUnavailable(
            $this->postJson('/v1/pairing/complete', [...$payload, 'nonce' => $this->base64Url($wrongNonce), 'ciphertext' => $this->base64Url($wrongSecret)]),
        );
        $this->assertSame('pending', $intent->fresh()->state);

        $response = $this->postJson('/v1/pairing/complete', $payload);

        $response->assertCreated()->assertJsonPath('state', 'pending_confirmation');
        $this->postJson('/v1/pairing/complete', $payload)
            ->assertCreated()
            ->assertExactJson($response->json());
        $changedNonce = random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES);
        $changedCiphertext = sodium_crypto_aead_xchacha20poly1305_ietf_encrypt(
            $secret, $this->aad($intent->intent_id_bytes, sodium_crypto_kx_publickey($client)), $changedNonce, $keys[0],
        );
        $this->assertPairingUnavailable(
            $this->postJson('/v1/pairing/complete', [...$payload, 'nonce' => $this->base64Url($changedNonce), 'ciphertext' => $this->base64Url($changedCiphertext)]),
        );
        $clientKeys = sodium_crypto_kx_client_session_keys($client, sodium_crypto_kx_publickey($server));
        $responsePlaintext = sodium_crypto_aead_xchacha20poly1305_ietf_decrypt(
            $this->decodeBase64Url((string) $response->json('ciphertext')),
            pack('n', 41).'openpaycongo/pairing/complete-response/v2'.pack('n', 16).$intent->intent_id_bytes,
            $this->decodeBase64Url((string) $response->json('nonce')),
            $clientKeys[0],
        );
        self::assertIsString($responsePlaintext);
        self::assertMatchesRegularExpression('/^[0-9]{6}$/', (string) json_decode($responsePlaintext, true, 512, JSON_THROW_ON_ERROR)['short_authentication_code']);
        $this->assertSame('pending_confirmation', $intent->fresh()->state);
        $this->assertSame('', $intent->fresh()->protected_server_private_material);
        $this->assertNotSame('', $intent->fresh()->server_receive_key);
        $this->assertNotSame('', $intent->fresh()->server_send_key);
    }

    public function test_expiry_after_completion_removes_replay_and_directional_key_material(): void
    {
        $expiresAt = now()->addMinute();
        [$intent, $payload] = $this->newPendingEnvelope(random_bytes(16), $expiresAt);

        $this->postJson('/v1/pairing/complete', $payload)->assertCreated();
        $this->travelTo($expiresAt->addSecond());

        $this->assertPairingUnavailable($this->postJson('/v1/pairing/complete', $payload));

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

    public function test_completion_rejects_extra_request_members_before_and_after_a_valid_consume(): void
    {
        [$intent, $payload] = $this->newPendingEnvelope(random_bytes(16), now()->addMinute());
        $withExtraMember = [...$payload, 'unexpected' => 'ignored-by-no-one'];

        $this->assertPairingUnavailable($this->postJson('/v1/pairing/complete', $withExtraMember));
        self::assertSame('pending', $intent->fresh()->state);

        $this->postJson('/v1/pairing/complete', $payload)->assertCreated();

        $this->assertPairingUnavailable($this->postJson('/v1/pairing/complete', $withExtraMember));
        self::assertSame('pending_confirmation', $intent->fresh()->state);
    }

    public function test_completion_rejects_noncanonical_base64url_after_a_valid_consume(): void
    {
        [$intent, $payload] = $this->newPendingEnvelope(random_bytes(16), now()->addMinute());

        $this->postJson('/v1/pairing/complete', $payload)->assertCreated();
        $noncanonical = $this->nonCanonicalBase64Url($payload['client_public_key']);
        self::assertSame($this->decodeBase64Url($payload['client_public_key']), $this->decodeBase64Url($noncanonical));

        $this->assertPairingUnavailable($this->postJson('/v1/pairing/complete', [...$payload, 'client_public_key' => $noncanonical]));
        self::assertSame('pending_confirmation', $intent->fresh()->state);
    }

    public function test_case_mutated_intent_id_cannot_select_a_different_binary_intent(): void
    {
        [$upperIntent, $upperPayload] = $this->newPendingEnvelope(hex2bin('000102030405060708090a0b0c0d0e0f'), now()->addMinute());
        [$lowerIntent, $lowerPayload] = $this->newPendingEnvelope(hex2bin('680102030405060708090a0b0c0d0e0f'), now()->addMinute());

        self::assertSame('A', $upperIntent->intent_id[0]);
        self::assertSame('a', $lowerIntent->intent_id[0]);
        $caseMutatedPayload = [...$upperPayload, 'intent_id' => $lowerIntent->intent_id];

        $this->assertPairingUnavailable($this->postJson('/v1/pairing/complete', $caseMutatedPayload));
        self::assertSame('pending', $upperIntent->fresh()->state);
        self::assertSame('pending', $lowerIntent->fresh()->state);
        $this->postJson('/v1/pairing/complete', $upperPayload)->assertCreated();
        $this->postJson('/v1/pairing/complete', $lowerPayload)->assertCreated();
    }

    private function aad(string $intent, string $clientPublicKey): string
    {
        return implode('', [pack('n', 32), 'openpaycongo/pairing/complete/v2', pack('n', 16), $intent, pack('n', 32), $clientPublicKey]);
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

    private function nonCanonicalBase64Url(string $value): string
    {
        foreach (str_split('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_') as $replacement) {
            $candidate = substr($value, 0, -1).$replacement;
            if ($candidate !== $value && $this->decodeBase64Url($candidate) === $this->decodeBase64Url($value)) {
                return $candidate;
            }
        }

        self::fail('Expected an alternate base64url representation.');
    }

    /** @return array{PairingIntent, array{intent_id: string, client_public_key: string, nonce: string, ciphertext: string}} */
    private function newPendingEnvelope(string $intentBytes, \DateTimeInterface $expiresAt): array
    {
        $organization = Organization::query()->create();
        $seed = random_bytes(SODIUM_CRYPTO_KX_SEEDBYTES);
        $server = sodium_crypto_kx_seed_keypair($seed);
        $client = sodium_crypto_kx_keypair();
        $secret = random_bytes(32);
        $intentId = $this->base64Url($intentBytes);
        $intent = PairingIntent::query()->create([
            'organization_id' => $organization->getKey(),
            'intent_id' => $intentId,
            'intent_id_bytes' => $intentBytes,
            'state' => 'pending',
            'expires_at' => $expiresAt,
            'protected_server_private_material' => app(KeyProtector::class)->protect(
                $seed,
                'openpaycongo/pairing/intent-server-private-material/v1/'.$organization->getKey().'/'.$intentId,
            ),
            'pairing_secret_digest' => hash('sha256', $secret),
            'server_key_agreement_public_key' => $this->base64Url(sodium_crypto_kx_publickey($server)),
        ]);
        $keys = sodium_crypto_kx_server_session_keys($server, sodium_crypto_kx_publickey($client));
        $nonce = random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES);

        return [$intent, [
            'intent_id' => $intentId,
            'client_public_key' => $this->base64Url(sodium_crypto_kx_publickey($client)),
            'nonce' => $this->base64Url($nonce),
            'ciphertext' => $this->base64Url(sodium_crypto_aead_xchacha20poly1305_ietf_encrypt(
                $secret,
                $this->aad($intentBytes, sodium_crypto_kx_publickey($client)),
                $nonce,
                $keys[0],
            )),
        ]];
    }

    private function assertPairingUnavailable(TestResponse $response): void
    {
        $response->assertNotFound()
            ->assertHeader('Content-Type', 'application/problem+json')
            ->assertJsonPath('type', 'https://openpaycongo.example/problems/pairing-unavailable')
            ->assertJsonPath('title', 'Pairing unavailable')
            ->assertJsonPath('status', 404)
            ->assertJsonPath('code', 'pairing_unavailable')
            ->assertJsonStructure(['type', 'title', 'status', 'code', 'request_id']);

        self::assertSame(['type', 'title', 'status', 'code', 'request_id'], array_keys($response->json()));
        self::assertMatchesRegularExpression('/^[0-9a-f-]{36}$/', (string) $response->json('request_id'));
        self::assertSame(
            ['no-store', 'private'],
            array_values(array_intersect(
                ['no-store', 'private'],
                array_map('trim', explode(',', (string) $response->headers->get('Cache-Control'))),
            )),
        );
    }
}
