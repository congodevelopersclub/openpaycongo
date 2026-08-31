<?php

declare(strict_types=1);

namespace App\Pairing;

/** Protects exactly one pairing secret before durable storage. */
interface KeyProtector
{
    /**
     * @throws \RuntimeException when material cannot be protected safely
     */
    public function protect(string $material, string $aad): string;

    /**
     * @throws \RuntimeException when protected material is unavailable or invalid
     */
    public function unprotect(string $protectedMaterial, string $aad): string;
}
