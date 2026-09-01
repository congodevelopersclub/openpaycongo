<?php

declare(strict_types=1);

namespace App\Pairing;

use App\Models\PairingIntent;
use Carbon\CarbonImmutable;
use Illuminate\Support\Facades\DB;

final class CompletePairingEnvelope
{
    private const int INVALID_PROOF_ATTEMPT_BUDGET = 3;

    public function __construct(private readonly KeyProtector $protector) {}

    public function execute(string $intentIdBytes, string $clientPublicKey, string $nonce, string $ciphertext, string $requestDigest): ?array
    {
        if (strlen($intentIdBytes) !== 16
            || strlen($clientPublicKey) !== SODIUM_CRYPTO_KX_PUBLICKEYBYTES
            || strlen($nonce) !== SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES
            || strlen($ciphertext) !== 32 + SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_ABYTES
            || strlen($requestDigest) !== 32) {
            return null;
        }
        $intentId = $this->base64Url($intentIdBytes);

        return DB::transaction(function () use ($intentId, $intentIdBytes, $clientPublicKey, $nonce, $ciphertext, $requestDigest): ?array {
            $intent = PairingIntent::query()->lockForUpdate()->where('intent_id_bytes', $intentIdBytes)->first();
            if ($intent instanceof PairingIntent && ! hash_equals($intentId, (string) $intent->intent_id)) {
                return null;
            }
            if ($intent instanceof PairingIntent && CarbonImmutable::parse($intent->expires_at)->lessThanOrEqualTo(CarbonImmutable::now('UTC'))) {
                $intent->forceFill([
                    'state' => 'expired',
                    'protected_server_private_material' => '',
                    'pairing_secret_digest' => null,
                    'server_receive_key' => null,
                    'server_send_key' => null,
                    'short_authentication_code' => null,
                    'completion_request_digest' => null,
                    'completion_result' => null,
                ])->save();

                return null;
            }
            if ($intent instanceof PairingIntent
                && $intent->state === 'pending_confirmation'
                && hash_equals((string) $intent->completion_request_digest, bin2hex($requestDigest))
                && is_string($intent->completion_result)) {
                /** @var array{state: string, nonce: string, ciphertext: string} $result */
                $result = json_decode($intent->completion_result, true, 3, JSON_THROW_ON_ERROR);

                return [
                    'state' => $result['state'],
                    'nonce' => base64_decode($result['nonce'], true),
                    'ciphertext' => base64_decode($result['ciphertext'], true),
                ];
            }
            if (! ($intent instanceof PairingIntent) || $intent->state !== 'pending') {
                return null;
            }
            $seed = $this->protector->unprotect(
                (string) $intent->protected_server_private_material,
                $this->intentAad($intent->organization_id, $intentId),
            );
            if (strlen($seed) !== SODIUM_CRYPTO_KX_SEEDBYTES) {
                return null;
            }
            $serverPair = sodium_crypto_kx_seed_keypair($seed);
            $keys = sodium_crypto_kx_server_session_keys($serverPair, $clientPublicKey);
            $secret = sodium_crypto_aead_xchacha20poly1305_ietf_decrypt($ciphertext, $this->aad($intent->intent_id_bytes, $clientPublicKey), $nonce, $keys[0]);
            $validProof = is_string($secret)
                && hash_equals((string) $intent->pairing_secret_digest, hash('sha256', $secret));
            if (is_string($secret)) {
                sodium_memzero($secret);
            }
            if (! $validProof) {
                $this->recordInvalidProof($intent);

                return null;
            }
            $sas = str_pad((string) random_int(0, 999999), 6, '0', STR_PAD_LEFT);
            $intent->forceFill([
                'state' => 'pending_confirmation',
                'server_receive_key' => $keys[0],
                'server_send_key' => $keys[1],
                'short_authentication_code' => $sas,
                'protected_server_private_material' => '',
                'pairing_secret_digest' => null,
            ])->save();
            $responseNonce = random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES);
            $response = sodium_crypto_aead_xchacha20poly1305_ietf_encrypt(
                json_encode(['state' => 'pending_confirmation', 'short_authentication_code' => $sas], JSON_THROW_ON_ERROR),
                $this->responseAad($intent->intent_id_bytes),
                $responseNonce,
                $keys[1],
            );
            $intent->forceFill([
                'completion_request_digest' => bin2hex($requestDigest),
                'completion_result' => json_encode([
                    'state' => 'pending_confirmation',
                    'nonce' => base64_encode($responseNonce),
                    'ciphertext' => base64_encode($response),
                ], JSON_THROW_ON_ERROR),
            ])->save();

            return ['state' => 'pending_confirmation', 'nonce' => $responseNonce, 'ciphertext' => $response];
        });
    }

    private function recordInvalidProof(PairingIntent $intent): void
    {
        $attempts = (int) $intent->invalid_proof_attempts + 1;
        if ($attempts >= self::INVALID_PROOF_ATTEMPT_BUDGET) {
            $intent->forceFill([
                'state' => 'exhausted',
                'invalid_proof_attempts' => $attempts,
                'protected_server_private_material' => '',
                'pairing_secret_digest' => null,
                'server_receive_key' => null,
                'server_send_key' => null,
                'short_authentication_code' => null,
                'completion_request_digest' => null,
                'completion_result' => null,
            ])->save();

            return;
        }

        $intent->forceFill(['invalid_proof_attempts' => $attempts])->save();
    }

    private function aad(string $intent, string $client): string
    {
        return pack('n', 32).'openpaycongo/pairing/complete/v2'.pack('n', 16).$intent.pack('n', 32).$client;
    }

    private function responseAad(string $intent): string
    {
        return pack('n', 41).'openpaycongo/pairing/complete-response/v2'.pack('n', 16).$intent;
    }

    private function intentAad(string $organizationId, string $intentId): string
    {
        return 'openpaycongo/pairing/intent-server-private-material/v1/'.$organizationId.'/'.$intentId;
    }

    private function base64Url(string $value): string
    {
        return rtrim(strtr(base64_encode($value), '+/', '-_'), '=');
    }
}
