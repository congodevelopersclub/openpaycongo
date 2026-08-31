<?php

declare(strict_types=1);

namespace App\Pairing;

use Illuminate\Support\Facades\Crypt;
use Throwable;

final class LaravelKeyProtector implements KeyProtector
{
    public function protect(string $material, string $aad): string
    {
        $this->assertInput($material, $aad);

        try {
            return Crypt::encryptString(json_encode([
                'aad' => $aad,
                'material' => base64_encode($material),
            ], JSON_THROW_ON_ERROR));
        } catch (Throwable $exception) {
            throw new PairingIntentUnavailable(previous: $exception);
        }
    }

    public function unprotect(string $protectedMaterial, string $aad): string
    {
        if ($protectedMaterial === '' || strlen($protectedMaterial) > 1024 || $aad === '' || strlen($aad) > 512) {
            throw new PairingIntentUnavailable;
        }

        try {
            /** @var array{aad: mixed, material: mixed} $envelope */
            $envelope = json_decode(Crypt::decryptString($protectedMaterial), true, 2, JSON_THROW_ON_ERROR);
            $material = is_string($envelope['material'] ?? null) ? base64_decode($envelope['material'], true) : false;

            if (! is_string($envelope['aad'] ?? null)
                || ! hash_equals($aad, $envelope['aad'])
                || $material === false
                || strlen($material) !== 32) {
                throw new PairingIntentUnavailable;
            }

            return $material;
        } catch (PairingIntentUnavailable $exception) {
            throw $exception;
        } catch (Throwable $exception) {
            throw new PairingIntentUnavailable(previous: $exception);
        }
    }

    private function assertInput(string $material, string $aad): void
    {
        if (strlen($material) !== 32 || $aad === '' || strlen($aad) > 512) {
            throw new PairingIntentUnavailable;
        }
    }
}
