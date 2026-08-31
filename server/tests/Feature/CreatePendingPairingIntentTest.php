<?php

namespace Tests\Feature;

use App\Models\Organization;
use App\Pairing\CreatePendingPairingIntent;
use App\Pairing\KeyProtector;
use App\Pairing\LaravelKeyProtector;
use App\Pairing\PairingIntentUnavailable;
use DateTimeImmutable;
use DateTimeZone;
use Illuminate\Foundation\Testing\RefreshDatabase;
use InvalidArgumentException;
use RuntimeException;
use Tests\TestCase;

final class CreatePendingPairingIntentTest extends TestCase
{
    use RefreshDatabase;

    public function test_it_persists_only_protected_pending_pairing_material(): void
    {
        $organization = Organization::query()->create();
        $intentId = rtrim(strtr(base64_encode(random_bytes(16)), '+/', '-_'), '=');
        $privateMaterial = random_bytes(32);
        $protector = new RecordingKeyProtector;

        $intent = (new CreatePendingPairingIntent($protector))->execute(
            organizationId: $organization->getKey(),
            intentId: $intentId,
            expiresAt: now()->addMinute(),
            serverPrivateMaterial: $privateMaterial,
        );

        $this->assertSame('pending', $intent->state);
        $this->assertSame($organization->getKey(), $intent->organization_id);
        $this->assertSame($intentId, $intent->intent_id);
        $this->assertSame($protector->protectedValue, $intent->protected_server_private_material);
        $this->assertNotContains('protected_server_private_material', $intent->toArray());
        $this->assertSame(
            'openpaycongo/pairing/intent-server-private-material/v1/'.$organization->getKey().'/'.$intentId,
            $protector->aad,
        );
        $this->assertSame(base64_decode(strtr($intentId, '-_', '+/'), true), $intent->intent_id_bytes);
    }

    public function test_uppercase_organization_uuid_is_rejected_before_aad_derivation_or_persistence(): void
    {
        $organization = Organization::query()->create();
        $protector = new RecordingKeyProtector;

        $this->expectException(InvalidArgumentException::class);

        try {
            (new CreatePendingPairingIntent($protector))->execute(
                strtoupper($organization->getKey()),
                rtrim(strtr(base64_encode(random_bytes(16)), '+/', '-_'), '='),
                now()->addMinute(),
                random_bytes(32),
            );
        } finally {
            $this->assertSame('', $protector->aad);
            $this->assertDatabaseCount('pairing_intents', 0);
        }
    }

    public function test_canonical_organization_uuid_survives_a_fresh_database_reload_for_key_unprotection(): void
    {
        $organization = Organization::query()->create();
        $intentId = rtrim(strtr(base64_encode(random_bytes(16)), '+/', '-_'), '=');
        $material = random_bytes(32);
        $protector = app(KeyProtector::class);
        $intent = (new CreatePendingPairingIntent($protector))->execute(
            $organization->getKey(), $intentId, now()->addMinute(), $material,
        );
        $reloaded = $intent->fresh();

        $this->assertSame(strtolower($organization->getKey()), $reloaded->organization_id);
        $this->assertSame(
            $material,
            $protector->unprotect(
                $reloaded->protected_server_private_material,
                'openpaycongo/pairing/intent-server-private-material/v1/'.$reloaded->organization_id.'/'.$reloaded->intent_id,
            ),
        );
    }

    public function test_case_distinct_canonical_intent_ids_persist_through_binary_unique_identity(): void
    {
        $organization = Organization::query()->create();
        $creator = new CreatePendingPairingIntent(new RecordingKeyProtector);
        $upper = 'AAECAwQFBgcICQoLDA0ODw';
        $lower = 'aAECAwQFBgcICQoLDA0ODw';

        $creator->execute($organization->getKey(), $upper, now()->addMinute(), random_bytes(32));
        $creator->execute($organization->getKey(), $lower, now()->addMinute(), random_bytes(32));

        $this->assertDatabaseCount('pairing_intents', 2);
    }

    public function test_protection_failure_leaves_no_pairing_intent(): void
    {
        $organization = Organization::query()->create();

        try {
            (new CreatePendingPairingIntent(new FailingKeyProtector))->execute(
                organizationId: $organization->getKey(),
                intentId: rtrim(strtr(base64_encode(random_bytes(16)), '+/', '-_'), '='),
                expiresAt: now()->addMinute(),
                serverPrivateMaterial: random_bytes(32),
            );
            $this->fail('Expected protection failure.');
        } catch (RuntimeException) {
            $this->assertDatabaseCount('pairing_intents', 0);
        }
    }

    public function test_noncanonical_pairing_intent_ids_are_rejected_without_persistence(): void
    {
        $organization = Organization::query()->create();
        $canonicalIntentId = rtrim(strtr(base64_encode(str_repeat("\xff", 16)), '+/', '-_'), '=');
        $creator = new CreatePendingPairingIntent(new RecordingKeyProtector);

        foreach ([
            $canonicalIntentId.'==',
            strtr($canonicalIntentId, '_', '/'),
            substr($canonicalIntentId, 0, 21),
        ] as $invalidIntentId) {
            try {
                $creator->execute($organization->getKey(), $invalidIntentId, now()->addMinute(), random_bytes(32));
                $this->fail('Expected noncanonical pairing intent ID rejection.');
            } catch (InvalidArgumentException) {
                $this->assertDatabaseCount('pairing_intents', 0);
            }
        }
    }

    public function test_laravel_protection_binds_the_exact_aad_and_fails_closed_for_tampering(): void
    {
        $protector = app(KeyProtector::class);
        $material = random_bytes(32);
        $aad = 'openpaycongo/pairing/test-aad';

        $this->assertInstanceOf(LaravelKeyProtector::class, $protector);
        $protectedMaterial = $protector->protect($material, $aad);
        $this->assertNotSame($material, $protectedMaterial);
        $this->assertSame($material, $protector->unprotect($protectedMaterial, $aad));

        foreach ([[$protectedMaterial.'x', $aad], [$protectedMaterial, $aad.'-other']] as [$invalidMaterial, $invalidAad]) {
            try {
                $protector->unprotect($invalidMaterial, $invalidAad);
                $this->fail('Expected protected material rejection.');
            } catch (PairingIntentUnavailable) {
                $this->assertTrue(true);
            }
        }
    }

    public function test_laravel_protection_rejects_maximum_accepted_aad_when_ciphertext_would_exceed_storage_bound(): void
    {
        $protector = app(KeyProtector::class);

        $this->expectException(PairingIntentUnavailable::class);
        $protector->protect(random_bytes(32), str_repeat('a', 512));
    }

    public function test_non_utc_expiry_persists_as_the_same_utc_instant(): void
    {
        $organization = Organization::query()->create();
        $expiresAt = new DateTimeImmutable('+60 seconds', new DateTimeZone('Asia/Kolkata'));
        $intent = (new CreatePendingPairingIntent(new RecordingKeyProtector))->execute(
            $organization->getKey(), rtrim(strtr(base64_encode(random_bytes(16)), '+/', '-_'), '='), $expiresAt, random_bytes(32),
        );

        $this->assertSame(
            $expiresAt->setTimezone(new DateTimeZone('UTC'))->format('Y-m-d\\TH:i:sP'),
            $intent->fresh()->expires_at->setTimezone(new DateTimeZone('UTC'))->format('Y-m-d\\TH:i:sP'),
        );
    }

    public function test_duplicate_intent_id_fails_closed_without_replacing_original_record(): void
    {
        $organization = Organization::query()->create();
        $intentId = rtrim(strtr(base64_encode(random_bytes(16)), '+/', '-_'), '=');
        $creator = new CreatePendingPairingIntent(new RecordingKeyProtector);
        $original = $creator->execute($organization->getKey(), $intentId, now()->addMinute(), random_bytes(32));

        $this->expectException(PairingIntentUnavailable::class);

        try {
            $creator->execute($organization->getKey(), $intentId, now()->addMinute(), random_bytes(32));
        } finally {
            $this->assertDatabaseCount('pairing_intents', 1);
            $this->assertSame($original->getKey(), $original->fresh()->getKey());
        }
    }
}

final class RecordingKeyProtector implements KeyProtector
{
    public string $protectedValue = 'opaque-protected-material';

    public string $aad = '';

    public function protect(string $material, string $aad): string
    {
        $this->aad = $aad;

        return $this->protectedValue;
    }

    public function unprotect(string $protectedMaterial, string $aad): string
    {
        throw new RuntimeException('Not exercised by this fixture.');
    }
}

final class FailingKeyProtector implements KeyProtector
{
    public function protect(string $material, string $aad): string
    {
        throw new RuntimeException('Key protection unavailable.');
    }

    public function unprotect(string $protectedMaterial, string $aad): string
    {
        throw new RuntimeException('Key protection unavailable.');
    }
}
