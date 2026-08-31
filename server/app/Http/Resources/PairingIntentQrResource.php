<?php

declare(strict_types=1);

namespace App\Http\Resources;

use App\Pairing\IssuedPairingIntent;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

/** @mixin IssuedPairingIntent */
final class PairingIntentQrResource extends JsonResource
{
    /** @return array<string, string> */
    public function toArray(Request $request): array
    {
        /** @var IssuedPairingIntent $issued */
        $issued = $this->resource;

        return [
            'version' => $issued->qr['version'],
            'endpoint' => $issued->qr['endpoint'],
            'intent_id' => $issued->qr['intent_id'],
            'intent_nonce' => $issued->qr['intent_nonce'],
            'expires_at' => $issued->qr['expires_at'],
            'algorithms' => $issued->qr['algorithms'],
            'enrollment_signing_fingerprint' => $issued->qr['enrollment_signing_fingerprint'],
            'enrollment_signing_public_key' => $issued->qr['enrollment_signing_public_key'],
            'server_key_agreement_public_key' => $issued->qr['server_key_agreement_public_key'],
            'trust_mode' => $issued->qr['trust_mode'],
            'signature' => $issued->qr['signature'],
        ];
    }
}
