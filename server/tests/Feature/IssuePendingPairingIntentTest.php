<?php

namespace Tests\Feature;

use App\Models\Organization;
use App\Pairing\IssuePendingPairingIntent;
use App\Pairing\KeyProtector;
use App\Pairing\PairingIntentUnavailable;
use App\Pairing\PairingRandom;
use Illuminate\Foundation\Testing\RefreshDatabase;
use InvalidArgumentException;
use RuntimeException;
use Tests\TestCase;

final class IssuePendingPairingIntentTest extends TestCase
{
    use RefreshDatabase;

    public function test_it_issues_and_independently_verifies_an_exact_signed_public_qr(): void
    {
        $this->travelTo('2026-09-01 12:00:00 UTC');
        $organization = Organization::query()->create();
        $privateKey = str_repeat("\x11", 32);
        $random = new SequencePairingRandom([
            hex2bin('000102030405060708090a0b0c0d0e0f'),
            str_repeat("\x22", 32),
            $privateKey,
        ]);
        $protector = new IssuanceRecordingProtector;
        $this->pairingConfig();

        $issued = (new IssuePendingPairingIntent($protector, $random))->execute($organization->getKey(), 60);
        $qr = $issued->qr;

        $this->assertSame('AAECAwQFBgcICQoLDA0ODw', $qr['intent_id']);
        $this->assertSame('IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI', $qr['intent_nonce']);
        $this->assertSame('2026-09-01T12:01:00Z', $qr['expires_at']);
        $this->assertSame('https://pairing.example.test/v1/pairing/complete', $qr['endpoint']);
        $this->assertSame('pinned_continuity', $qr['trust_mode']);
        $this->assertSame(
            sodium_crypto_scalarmult_base($privateKey),
            base64_decode(strtr($qr['server_key_agreement_public_key'], '-_', '+/'), true),
        );
        $this->assertSame(
            hash('sha256', base64_decode(strtr($qr['enrollment_signing_public_key'], '-_', '+/'), true), true),
            base64_decode(strtr($qr['enrollment_signing_fingerprint'], '-_', '+/'), true),
        );
        $this->assertTrue(sodium_crypto_sign_verify_detached(
            base64_decode(strtr($qr['signature'], '-_', '+/'), true),
            $this->qrTranscript($qr),
            base64_decode(strtr($qr['enrollment_signing_public_key'], '-_', '+/'), true),
        ));
        $this->assertSame($privateKey, $protector->material);
        $this->assertSame(
            'openpaycongo/pairing/intent-server-private-material/v1/'.$organization->getKey().'/'.$qr['intent_id'],
            $protector->aad,
        );
        $this->assertDatabaseMissing('pairing_intents', ['protected_server_private_material' => $privateKey]);
        $this->assertNotContains('protected_server_private_material', array_keys($issued->intent->toArray()));
        $this->assertStringNotContainsString($privateKey, json_encode($issued, JSON_THROW_ON_ERROR));
    }

    public function test_malformed_configuration_fails_before_protection_or_persistence(): void
    {
        $organization = Organization::query()->create();
        $protector = new IssuanceRecordingProtector;
        config()->set('openpay.pairing', [
            'endpoint' => 'https://PAIRING.example.test/v1/pairing/complete',
            'enrollment_signing_secret' => $this->base64Url(str_repeat("\x01", 32)),
            'trust_mode' => 'pinned_continuity',
        ]);

        $this->expectException(InvalidArgumentException::class);

        try {
            (new IssuePendingPairingIntent($protector, new SequencePairingRandom([])))->execute($organization->getKey(), 60);
        } finally {
            $this->assertSame('', $protector->material);
            $this->assertDatabaseCount('pairing_intents', 0);
        }
    }

    public function test_uppercase_organization_uuid_fails_before_configuration_crypto_or_persistence(): void
    {
        $organization = Organization::query()->create();
        $protector = new IssuanceRecordingProtector;
        config()->set('openpay.pairing', null);

        $this->expectException(InvalidArgumentException::class);
        $this->expectExceptionMessage('Invalid pairing intent input.');

        try {
            (new IssuePendingPairingIntent($protector, new SequencePairingRandom([])))->execute(
                strtoupper($organization->getKey()),
                60,
            );
        } finally {
            $this->assertSame('', $protector->material);
            $this->assertDatabaseCount('pairing_intents', 0);
        }
    }

    public function test_out_of_bounds_expiry_and_trust_mode_fail_before_persistence(): void
    {
        $organization = Organization::query()->create();
        $this->pairingConfig(['trust_mode' => 'unsafe']);

        try {
            (new IssuePendingPairingIntent(new IssuanceRecordingProtector, new SequencePairingRandom([])))->execute($organization->getKey(), 60);
            $this->fail('Expected invalid pairing configuration.');
        } catch (InvalidArgumentException) {
            $this->assertDatabaseCount('pairing_intents', 0);
        }

        $this->pairingConfig();

        foreach ([29, 301] as $lifetime) {
            try {
                (new IssuePendingPairingIntent(new IssuanceRecordingProtector, new SequencePairingRandom([])))->execute($organization->getKey(), $lifetime);
                $this->fail('Expected invalid pairing lifetime.');
            } catch (InvalidArgumentException) {
                $this->assertDatabaseCount('pairing_intents', 0);
            }
        }
    }

    public function test_random_intent_id_collision_fails_closed_without_replacing_original(): void
    {
        $organization = Organization::query()->create();
        $this->pairingConfig();
        $id = hex2bin('000102030405060708090a0b0c0d0e0f');
        $first = (new IssuePendingPairingIntent(new IssuanceRecordingProtector, new SequencePairingRandom([
            $id, str_repeat("\x02", 32), str_repeat("\x03", 32),
        ])))->execute($organization->getKey(), 60);

        $this->expectException(PairingIntentUnavailable::class);

        try {
            (new IssuePendingPairingIntent(new IssuanceRecordingProtector, new SequencePairingRandom([
                $id, str_repeat("\x04", 32), str_repeat("\x05", 32),
            ])))->execute($organization->getKey(), 60);
        } finally {
            $this->assertDatabaseCount('pairing_intents', 1);
            $this->assertSame($first->intent->getKey(), $first->intent->fresh()->getKey());
        }
    }

    /** @param array<string, string> $overrides */
    private function pairingConfig(array $overrides = []): void
    {
        config()->set('openpay.pairing', array_merge([
            'endpoint' => 'https://pairing.example.test/v1/pairing/complete',
            'enrollment_signing_secret' => $this->base64Url(str_repeat("\x01", 32)),
            'trust_mode' => 'pinned_continuity',
        ], $overrides));
    }

    /** @param array<string, string> $qr */
    private function qrTranscript(array $qr): string
    {
        $decode = fn (string $value): string => base64_decode(strtr($value, '-_', '+/'), true);
        $field = static fn (string $value): string => pack('n', strlen($value)).$value;

        return implode('', array_map($field, [
            'openpaycongo/pairing/qr', $qr['version'], $qr['endpoint'], $decode($qr['intent_id']),
            $decode($qr['intent_nonce']), $qr['expires_at'], $qr['algorithms'],
            $decode($qr['enrollment_signing_public_key']), $decode($qr['enrollment_signing_fingerprint']),
            $decode($qr['server_key_agreement_public_key']), $qr['trust_mode'],
        ]));
    }

    private function base64Url(string $value): string
    {
        return rtrim(strtr(base64_encode($value), '+/', '-_'), '=');
    }
}

final class SequencePairingRandom implements PairingRandom
{
    /** @param list<string> $values */
    public function __construct(private array $values) {}

    public function bytes(int $length): string
    {
        $value = array_shift($this->values);
        if (! is_string($value) || strlen($value) !== $length) {
            throw new RuntimeException('Unexpected random request.');
        }

        return $value;
    }
}

final class IssuanceRecordingProtector implements KeyProtector
{
    public string $material = '';

    public string $aad = '';

    public function protect(string $material, string $aad): string
    {
        $this->material = $material;
        $this->aad = $aad;

        return 'opaque-protected-material';
    }

    public function unprotect(string $protectedMaterial, string $aad): string
    {
        throw new RuntimeException('Not exercised by this fixture.');
    }
}
