<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\Models\SourceInstallation;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

final class MobileEnvelopeGatewayTest extends TestCase
{
    use RefreshDatabase;

    public function test_valid_encrypted_deposit_returns_an_encrypted_recorded_result(): void
    {
        $installation = $this->installation();
        $counter = '1';

        $response = $this->postJson('/mobile/envelopes', $this->envelope($installation, $counter, $this->depositPayload()));

        $response->assertCreated()->assertHeader('cache-control', 'no-store, private');
        $outer = $response->json();
        self::assertSame(['version', 'nonce', 'ciphertext'], array_keys($outer));
        self::assertSame(['outcome' => 'recorded'], $this->decryptResponse($installation, $counter, 201, $outer));
        self::assertSame(1, $installation->fresh()->mobile_replay_counter);
        self::assertDatabaseCount('deposits', 1);
        self::assertDatabaseCount('ledger_entries', 2);
    }

    public function test_android_v1_request_vector_decrypts_and_returns_an_encrypted_recorded_result(): void
    {
        $installation = new SourceInstallation;
        $installation->forceFill([
            'id' => '123e4567-e89b-12d3-a456-426614174000',
            'organization_id' => '00000000-0000-4000-8000-000000000001',
            'installation_digest' => hash('sha256', 'android-v1-vector'),
            'installation_lookup_id' => 'android-v1-vector',
            'installation_key_version' => 'v1',
            'mobile_receive_key' => hex2bin('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'),
            'mobile_send_key' => hex2bin('202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f'),
            'mobile_replay_counter' => 0,
        ]);
        $installation->save();

        $response = $this->postJson('/mobile/envelopes', [
            'version' => 1,
            'installation_id' => $installation->id,
            'counter' => '1',
            'nonce' => 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYX',
            'ciphertext' => '5eB5GuKh5MFdZhz_53DHmC41SdGUuXPJRThb003ChjAqJJrGMQZwCLr0ynv1WnEBBMmWNioRiUZr9PxW-pcbndZFkcdh_w3gXn0c4z0McdYscnm30HBO7Tn9WAWTPVE8HGsDJXN1ApSXaFuyQWQzP1Ud9dmAMgMQvAM7AhXsv4xgwAwurpVn-OP1WCZoxaLunyoG8iiuHjOTgiFY6pK9kkXf72uOJ-G20z96b3bR93aiw4yaIdIwVGymAtxoWQ6zjkOvj88rL9ReM68_FPnoO4lJ7VyX5R_lOtMcRHpG-t6JVCBGxgH39qw0wQ',
        ]);

        $response->assertCreated()->assertHeader('cache-control', 'no-store, private');
        self::assertSame(['version', 'nonce', 'ciphertext'], array_keys($response->json()));
        self::assertSame(['outcome' => 'recorded'], $this->decryptResponse($installation, '1', 201, $response->json()));
        self::assertSame(1, $installation->fresh()->mobile_replay_counter);
        self::assertDatabaseCount('deposits', 1);
        self::assertDatabaseCount('ledger_entries', 2);
    }

    public function test_lost_response_retries_same_deposit_under_the_next_counter_and_replays_the_result(): void
    {
        $installation = $this->installation();
        $payload = $this->depositPayload();

        $this->postJson('/mobile/envelopes', $this->envelope($installation, '1', $payload))->assertCreated();
        $response = $this->postJson('/mobile/envelopes', $this->envelope($installation, '2', $payload));

        $response->assertOk();
        self::assertSame(['outcome' => 'replayed'], $this->decryptResponse($installation, '2', 200, $response->json()));
        self::assertSame(2, $installation->fresh()->mobile_replay_counter);
        self::assertDatabaseCount('deposits', 1);
    }

    public function test_changed_replay_is_an_encrypted_conflict_and_consumes_its_authenticated_counter(): void
    {
        $installation = $this->installation();
        $payload = $this->depositPayload();

        $this->postJson('/mobile/envelopes', $this->envelope($installation, '1', $payload))->assertCreated();
        $response = $this->postJson('/mobile/envelopes', $this->envelope($installation, '2', [...$payload, 'amount_minor' => 12501]));

        $response->assertConflict();
        self::assertSame(['outcome' => 'conflict'], $this->decryptResponse($installation, '2', 409, $response->json()));
        self::assertSame(2, $installation->fresh()->mobile_replay_counter);
        self::assertDatabaseCount('deposits', 1);
    }

    public function test_tampered_ciphertext_and_stale_counter_are_indistinguishable_and_do_not_mutate_state(): void
    {
        $installation = $this->installation();
        $envelope = $this->envelope($installation, '1', $this->depositPayload());
        $firstCharacter = $envelope['ciphertext'][0];
        $envelope['ciphertext'] = ($firstCharacter === 'A' ? 'B' : 'A').substr($envelope['ciphertext'], 1);

        $this->postJson('/mobile/envelopes', $envelope)
            ->assertNotFound()
            ->assertExactJson(['code' => 'mobile_envelope_unavailable']);
        self::assertSame(0, $installation->fresh()->mobile_replay_counter);
        self::assertDatabaseCount('deposits', 0);

        $accepted = $this->envelope($installation, '1', $this->depositPayload());
        $this->postJson('/mobile/envelopes', $accepted)->assertCreated();
        $this->postJson('/mobile/envelopes', $accepted)
            ->assertNotFound()
            ->assertExactJson(['code' => 'mobile_envelope_unavailable']);
        self::assertSame(1, $installation->fresh()->mobile_replay_counter);
        self::assertDatabaseCount('deposits', 1);
    }

    public function test_outer_bounds_are_rejected_without_mutating_state(): void
    {
        $installation = $this->installation();
        $wrongNonceLength = $this->envelope($installation, '1', $this->depositPayload());
        $wrongNonceLength['nonce'] = str_repeat('A', 31);

        $this->postJson('/mobile/envelopes', $wrongNonceLength)
            ->assertNotFound()
            ->assertExactJson(['code' => 'mobile_envelope_unavailable'])
            ->assertHeader('cache-control', 'no-store, private');

        $oversizedCiphertext = $this->envelope($installation, '1', $this->depositPayload());
        $oversizedCiphertext['ciphertext'] = str_repeat('A', 16_386);

        $this->postJson('/mobile/envelopes', $oversizedCiphertext)
            ->assertNotFound()
            ->assertExactJson(['code' => 'mobile_envelope_unavailable'])
            ->assertHeader('cache-control', 'no-store, private');

        self::assertSame(0, $installation->fresh()->mobile_replay_counter);
        self::assertDatabaseCount('deposits', 0);
    }

    public function test_rate_limiting_is_per_origin_and_has_the_same_unavailable_boundary(): void
    {
        $limitedOrigin = '203.0.113.10';

        for ($attempt = 0; $attempt < 61; $attempt++) {
            $this->withServerVariables(['REMOTE_ADDR' => $limitedOrigin])
                ->postJson('/mobile/envelopes', [])
                ->assertNotFound()
                ->assertExactJson(['code' => 'mobile_envelope_unavailable'])
                ->assertHeader('cache-control', 'no-store, private');
        }

        $installation = $this->installation();

        $this->withServerVariables(['REMOTE_ADDR' => '203.0.113.11'])
            ->postJson('/mobile/envelopes', $this->envelope($installation, '1', $this->depositPayload()))
            ->assertCreated();
    }

    public function test_an_envelope_cannot_be_retargeted_to_another_installation(): void
    {
        $source = $this->installation();
        $target = $this->installation('00000000-0000-4000-8000-000000000003');
        $envelope = $this->envelope($source, '1', $this->depositPayload());
        $envelope['installation_id'] = $target->id;

        $this->postJson('/mobile/envelopes', $envelope)
            ->assertNotFound()
            ->assertExactJson(['code' => 'mobile_envelope_unavailable']);
        self::assertSame(0, $source->fresh()->mobile_replay_counter);
        self::assertSame(0, $target->fresh()->mobile_replay_counter);
        self::assertDatabaseCount('deposits', 0);
    }

    public function test_the_final_supported_counter_is_accepted_without_wraparound(): void
    {
        $installation = $this->installation();
        $counter = (string) PHP_INT_MAX;

        $response = $this->postJson('/mobile/envelopes', $this->envelope($installation, $counter, $this->depositPayload()));

        $response->assertCreated();
        self::assertSame(['outcome' => 'recorded'], $this->decryptResponse($installation, $counter, 201, $response->json()));
        self::assertSame(PHP_INT_MAX, $installation->fresh()->mobile_replay_counter);
    }

    private function installation(string $id = '00000000-0000-4000-8000-000000000002'): SourceInstallation
    {
        return SourceInstallation::query()->create([
            'id' => $id,
            'organization_id' => '00000000-0000-4000-8000-000000000001',
            'installation_digest' => hash('sha256', $id),
            'installation_lookup_id' => $id,
            'installation_key_version' => 'v1',
            'mobile_receive_key' => random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES),
            'mobile_send_key' => random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES),
            'mobile_replay_counter' => 0,
        ]);
    }

    /** @return array<string, int|string> */
    private function depositPayload(): array
    {
        return [
            'customer_lookup_identifier' => 'customer-001',
            'provider_reference' => 'envelope-reference-001',
            'amount_minor' => 12500,
            'currency' => 'CDF',
            'provider_occurred_at' => '2026-09-01T01:00:00Z',
        ];
    }

    /** @param array<string, int|string> $payload @return array<string, string|int> */
    private function envelope(SourceInstallation $installation, string $counter, array $payload): array
    {
        $nonce = random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES);
        $plaintext = json_encode(['version' => 1, 'operation' => 'deposit', 'payload' => $payload], JSON_THROW_ON_ERROR);
        $ciphertext = sodium_crypto_aead_xchacha20poly1305_ietf_encrypt($plaintext, $this->requestAad($installation->id, $counter), $nonce, $installation->mobile_receive_key);

        return [
            'version' => 1,
            'installation_id' => $installation->id,
            'counter' => $counter,
            'nonce' => $this->encode($nonce),
            'ciphertext' => $this->encode($ciphertext),
        ];
    }

    /** @param array<string, string|int> $outer @return array<string, string> */
    private function decryptResponse(SourceInstallation $installation, string $counter, int $status, array $outer): array
    {
        $plaintext = sodium_crypto_aead_xchacha20poly1305_ietf_decrypt(
            $this->decode((string) $outer['ciphertext']),
            $this->responseAad($installation->id, $counter, $status),
            $this->decode((string) $outer['nonce']),
            $installation->mobile_send_key,
        );
        self::assertNotFalse($plaintext);

        return json_decode($plaintext, true, 512, JSON_THROW_ON_ERROR);
    }

    private function requestAad(string $id, string $counter): string
    {
        return pack('n', 39).'openpaycongo/mobile/request-envelope/v1'.$this->uuid($id).$this->counterBytes($counter);
    }

    private function responseAad(string $id, string $counter, int $status): string
    {
        return pack('n', 40).'openpaycongo/mobile/response-envelope/v1'.$this->uuid($id).$this->counterBytes($counter).pack('n', $status);
    }

    private function counterBytes(string $counter): string
    {
        $value = (int) $counter;

        return pack('N2', intdiv($value, 4_294_967_296), $value % 4_294_967_296);
    }

    private function uuid(string $id): string
    {
        return hex2bin(str_replace('-', '', $id));
    }

    private function encode(string $value): string
    {
        return rtrim(strtr(base64_encode($value), '+/', '-_'), '=');
    }

    private function decode(string $value): string
    {
        return base64_decode(strtr($value.str_repeat('=', (4 - strlen($value) % 4) % 4), '-_', '+/'), true);
    }
}
