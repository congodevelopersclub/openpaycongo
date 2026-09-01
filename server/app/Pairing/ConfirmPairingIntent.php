<?php

declare(strict_types=1);

namespace App\Pairing;

use App\Models\PairingIntent;
use App\Models\SourceInstallation;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

final class ConfirmPairingIntent
{
    /** @var list<string> */
    private const array MOBILE_ABILITIES = [
        'mobile:deposits:write',
        'mobile:sync:read',
        'mobile:sync:write',
    ];

    /** @return array{status: string, expires_at: string, short_authentication_code?: string} */
    public function display(User $operator, string $intentId): array
    {
        return DB::transaction(function () use ($operator, $intentId): array {
            $intent = $this->intentFor($operator, $intentId);
            $this->expireIfDue($intent);

            $state = (string) $intent->state;
            $response = [
                'status' => $state,
                'expires_at' => CarbonImmutable::parse($intent->expires_at)->utc()->format('Y-m-d\\TH:i:s\\Z'),
            ];
            if ($state === 'pending_confirmation' && is_string($intent->short_authentication_code)) {
                $response['short_authentication_code'] = $intent->short_authentication_code;
            }

            return $response;
        });
    }

    public function confirm(User $operator, string $intentId, string $requestId, string $decision): string
    {
        return DB::transaction(function () use ($operator, $intentId, $requestId, $decision): string {
            $intent = $this->intentFor($operator, $intentId);
            $this->expireIfDue($intent);

            $requestDigest = hash('sha256', $requestId);
            if ($intent->state === 'expired') {
                return 'expired';
            }
            if ($this->isTerminal($intent)) {
                if (
                    is_string($intent->confirmation_request_digest)
                    && hash_equals($intent->confirmation_request_digest, $requestDigest)
                    && $intent->confirmation_decision === $decision
                ) {
                    return (string) $intent->state;
                }

                throw new PairingConfirmationConflict;
            }
            if ($intent->state !== 'pending_confirmation') {
                throw new PairingConfirmationUnavailable;
            }
            if ($decision === 'codes_mismatch') {
                $this->terminate($intent, 'revoked', $requestDigest, $decision);

                return 'revoked';
            }

            $receiveKey = $intent->server_receive_key;
            $sendKey = $intent->server_send_key;
            if (
                ! is_string($receiveKey)
                || strlen($receiveKey) !== SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES
                || ! is_string($sendKey)
                || strlen($sendKey) !== SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES
            ) {
                $this->terminate($intent, 'revoked', $requestDigest, $decision);

                return 'revoked';
            }

            $installation = SourceInstallation::query()->create([
                'organization_id' => $intent->organization_id,
                'installation_digest' => hash('sha256', random_bytes(32)),
                'installation_lookup_id' => (string) Str::uuid(),
                'installation_key_version' => 'pairing-v2',
                'mobile_receive_key' => $receiveKey,
                'mobile_send_key' => $sendKey,
                'mobile_replay_counter' => 0,
            ]);
            $issuedToken = $installation->createToken('paired-mobile-installation', self::MOBILE_ABILITIES);
            $activationPlaintext = json_encode([
                'version' => 2,
                'installation_id' => $installation->getKey(),
                'bearer_token' => $issuedToken->plainTextToken,
            ], JSON_THROW_ON_ERROR);
            $activationNonce = random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES);
            $activationCiphertext = sodium_crypto_aead_xchacha20poly1305_ietf_encrypt(
                $activationPlaintext,
                $this->activationAad($intent->intent_id_bytes),
                $activationNonce,
                $sendKey,
            );
            sodium_memzero($activationPlaintext);
            unset($issuedToken);
            $installation->forceFill([
                'pairing_intent_id' => $intent->intent_id,
                'activation_nonce' => $activationNonce,
                'activation_ciphertext' => $activationCiphertext,
            ])->save();
            $this->terminate($intent, 'active', $requestDigest, $decision);

            return 'active';
        });
    }

    private function intentFor(User $operator, string $intentId): PairingIntent
    {
        if (! $this->isCanonicalIntentId($intentId)) {
            throw new PairingConfirmationUnavailable;
        }

        $intent = PairingIntent::query()
            ->lockForUpdate()
            ->where('organization_id', $operator->organization_id)
            ->where('intent_id', $intentId)
            ->first();
        if (! $intent instanceof PairingIntent) {
            throw new PairingConfirmationUnavailable;
        }

        return $intent;
    }

    private function expireIfDue(PairingIntent $intent): void
    {
        if (
            in_array($intent->state, ['pending', 'pending_confirmation'], true)
            && CarbonImmutable::parse($intent->expires_at)->lessThanOrEqualTo(CarbonImmutable::now('UTC'))
        ) {
            $this->terminate($intent, 'expired');
        }
    }

    private function isTerminal(PairingIntent $intent): bool
    {
        return in_array($intent->state, ['active', 'revoked', 'expired', 'exhausted'], true);
    }

    private function terminate(
        PairingIntent $intent,
        string $state,
        ?string $requestDigest = null,
        ?string $decision = null,
    ): void {
        $intent->forceFill([
            'state' => $state,
            'protected_server_private_material' => '',
            'pairing_secret_digest' => null,
            'server_receive_key' => null,
            'server_send_key' => null,
            'short_authentication_code' => null,
            'completion_request_digest' => null,
            'completion_result' => null,
            'confirmation_request_digest' => $requestDigest,
            'confirmation_decision' => $decision,
        ])->save();
    }

    private function isCanonicalIntentId(string $value): bool
    {
        if (preg_match('/^[A-Za-z0-9_-]{22}$/D', $value) !== 1) {
            return false;
        }

        $decoded = base64_decode(strtr($value, '-_', '+/').'==', true);

        return is_string($decoded)
            && strlen($decoded) === 16
            && rtrim(strtr(base64_encode($decoded), '+/', '-_'), '=') === $value;
    }

    private function activationAad(string $intentId): string
    {
        return pack('n', 44).'openpaycongo/pairing/activation-response/v2'.pack('n', 16).$intentId;
    }
}
