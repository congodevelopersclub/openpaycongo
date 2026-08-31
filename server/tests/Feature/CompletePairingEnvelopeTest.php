<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\Models\Organization;
use App\Models\PairingIntent;
use App\Pairing\KeyProtector;
use Illuminate\Foundation\Testing\RefreshDatabase;
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
        $this->postJson('/v1/pairing/complete', [...$payload, 'ciphertext' => $this->base64Url($tampered)])
            ->assertNotFound();
        $wrongNonce = random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES);
        $wrongSecret = sodium_crypto_aead_xchacha20poly1305_ietf_encrypt(
            random_bytes(32), $this->aad($intent->intent_id_bytes, sodium_crypto_kx_publickey($client)), $wrongNonce, $keys[0],
        );
        $this->postJson('/v1/pairing/complete', [...$payload, 'nonce' => $this->base64Url($wrongNonce), 'ciphertext' => $this->base64Url($wrongSecret)])
            ->assertNotFound();
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
        $this->postJson('/v1/pairing/complete', [...$payload, 'nonce' => $this->base64Url($changedNonce), 'ciphertext' => $this->base64Url($changedCiphertext)])
            ->assertNotFound();
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
}
