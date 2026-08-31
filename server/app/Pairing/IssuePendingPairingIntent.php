<?php

declare(strict_types=1);

namespace App\Pairing;

use App\Models\PairingIntent;
use Carbon\CarbonImmutable;
use Illuminate\Database\QueryException;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use InvalidArgumentException;

final readonly class IssuePendingPairingIntent
{
    private const VERSION = '1';

    private const SUITE = 'X25519-HKDF-SHA256-AES-256-GCM+Ed25519';

    public function __construct(private KeyProtector $protector, private PairingRandom $random) {}

    public function execute(string $organizationId, int $lifetimeSeconds): IssuedPairingIntent
    {
        [$endpoint, $signingSeed, $trustMode] = $this->configuration();
        $this->assertInput($organizationId, $lifetimeSeconds);

        $intentId = $this->base64Url($this->random->bytes(16));
        $intentNonce = $this->base64Url($this->random->bytes(32));
        $serverPrivateKey = $this->random->bytes(32);
        $serverPublicKey = sodium_crypto_scalarmult_base($serverPrivateKey);
        $expiresAt = CarbonImmutable::now('UTC')->startOfSecond()->addSeconds($lifetimeSeconds);
        $keypair = sodium_crypto_sign_seed_keypair($signingSeed);
        $signingPublicKey = sodium_crypto_sign_publickey($keypair);
        $signingFingerprint = hash('sha256', $signingPublicKey, true);
        $qr = [
            'version' => self::VERSION,
            'endpoint' => $endpoint,
            'intent_id' => $intentId,
            'intent_nonce' => $intentNonce,
            'expires_at' => $expiresAt->format('Y-m-d\\TH:i:s\\Z'),
            'algorithms' => self::SUITE,
            'enrollment_signing_fingerprint' => $this->base64Url($signingFingerprint),
            'enrollment_signing_public_key' => $this->base64Url($signingPublicKey),
            'server_key_agreement_public_key' => $this->base64Url($serverPublicKey),
            'trust_mode' => $trustMode,
        ];
        $qr['signature'] = $this->base64Url(sodium_crypto_sign_detached(
            $this->qrTranscript($qr),
            sodium_crypto_sign_secretkey($keypair),
        ));
        $intentIdBytes = $this->decodeBase64Url($intentId, 16);
        $protectedPrivateKey = $this->protector->protect($serverPrivateKey, $this->aad($organizationId, $intentId));

        if ($protectedPrivateKey === '' || strlen($protectedPrivateKey) > 1024) {
            throw new PairingIntentUnavailable;
        }

        try {
            $intent = DB::transaction(static fn (): PairingIntent => PairingIntent::query()->create([
                'organization_id' => $organizationId,
                'intent_id' => $intentId,
                'intent_id_bytes' => $intentIdBytes,
                'state' => 'pending',
                'expires_at' => $expiresAt,
                'protected_server_private_material' => $protectedPrivateKey,
                'intent_nonce' => $qr['intent_nonce'],
                'enrollment_signing_public_key' => $qr['enrollment_signing_public_key'],
                'enrollment_signing_fingerprint' => $qr['enrollment_signing_fingerprint'],
                'server_key_agreement_public_key' => $qr['server_key_agreement_public_key'],
                'trust_mode' => $qr['trust_mode'],
            ]));
        } catch (QueryException $exception) {
            throw new PairingIntentUnavailable(previous: $exception);
        }

        return new IssuedPairingIntent($intent, $qr);
    }

    /** @return array{string, string, string} */
    private function configuration(): array
    {
        $configuration = config('openpay.pairing');
        $endpoint = is_array($configuration) ? $configuration['endpoint'] ?? null : null;
        $seed = is_array($configuration) ? $configuration['enrollment_signing_secret'] ?? null : null;
        $trustMode = is_array($configuration) ? $configuration['trust_mode'] ?? null : null;

        if (! is_string($endpoint) || ! $this->isCanonicalEndpoint($endpoint)
            || ! is_string($seed) || ($signingSeed = $this->decodeBase64Url($seed, 32)) === null
            || ! is_string($trustMode) || ! in_array($trustMode, ['first_use_requires_sas', 'pinned_continuity'], true)) {
            throw new InvalidArgumentException('Invalid pairing configuration.');
        }

        return [$endpoint, $signingSeed, $trustMode];
    }

    private function assertInput(string $organizationId, int $lifetimeSeconds): void
    {
        if (! Str::isUuid($organizationId) || $lifetimeSeconds < 30 || $lifetimeSeconds > 300) {
            throw new InvalidArgumentException('Invalid pairing intent input.');
        }
    }

    /** @param array<string, string> $qr */
    private function qrTranscript(array $qr): string
    {
        $fields = [
            'openpaycongo/pairing/qr', $qr['version'], $qr['endpoint'], $this->decodeBase64Url($qr['intent_id'], 16),
            $this->decodeBase64Url($qr['intent_nonce'], 32), $qr['expires_at'], $qr['algorithms'],
            $this->decodeBase64Url($qr['enrollment_signing_public_key'], 32),
            $this->decodeBase64Url($qr['enrollment_signing_fingerprint'], 32),
            $this->decodeBase64Url($qr['server_key_agreement_public_key'], 32), $qr['trust_mode'],
        ];
        $transcript = '';

        foreach ($fields as $field) {
            if (! is_string($field) || strlen($field) > 65535) {
                throw new InvalidArgumentException('Invalid QR transcript.');
            }
            $transcript .= pack('n', strlen($field)).$field;
        }

        if (strlen($transcript) > 4096) {
            throw new InvalidArgumentException('Invalid QR transcript.');
        }

        return $transcript;
    }

    private function isCanonicalEndpoint(string $endpoint): bool
    {
        if (preg_match('#\\Ahttps://(?<host>(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+(?:[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?))(?::(?<port>[1-9][0-9]{0,4}))?/v1/pairing/complete\\z#D', $endpoint, $matches) !== 1) {
            return false;
        }

        return strlen($matches['host']) <= 253
            && (! isset($matches['port']) || (int) $matches['port'] <= 65535);
    }

    private function aad(string $organizationId, string $intentId): string
    {
        return 'openpaycongo/pairing/intent-server-private-material/v1/'.$organizationId.'/'.$intentId;
    }

    private function base64Url(string $value): string
    {
        return rtrim(strtr(base64_encode($value), '+/', '-_'), '=');
    }

    private function decodeBase64Url(string $value, int $expectedLength): ?string
    {
        if (preg_match('/^[A-Za-z0-9_-]+$/D', $value) !== 1) {
            return null;
        }

        $decoded = base64_decode(strtr($value, '-_', '+/'), true);

        return is_string($decoded) && strlen($decoded) === $expectedLength && $this->base64Url($decoded) === $value
            ? $decoded
            : null;
    }
}
