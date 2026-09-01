<?php

declare(strict_types=1);

namespace App\Pairing;

use App\Models\SourceInstallation;

final class RetrievePairingActivation
{
    /** @return array{nonce: string, ciphertext: string}|null */
    public function execute(string $intentId): ?array
    {
        if (! $this->isCanonicalIntentId($intentId)) {
            return null;
        }

        $installation = SourceInstallation::query()
            ->where('pairing_intent_id', $intentId)
            ->first();
        if (! $installation instanceof SourceInstallation) {
            return null;
        }

        $nonce = $installation->activation_nonce;
        $ciphertext = $installation->activation_ciphertext;
        if (
            ! is_string($nonce)
            || strlen($nonce) !== SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES
            || ! is_string($ciphertext)
            || strlen($ciphertext) < SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_ABYTES
        ) {
            return null;
        }

        return ['nonce' => $nonce, 'ciphertext' => $ciphertext];
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
}
