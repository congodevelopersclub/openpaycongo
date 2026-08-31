<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;

final class PairingIntent extends Model
{
    use HasUuids;

    public $incrementing = false;

    protected $keyType = 'string';

    protected $fillable = [
        'organization_id',
        'intent_id',
        'intent_id_bytes',
        'state',
        'expires_at',
        'protected_server_private_material',
        'intent_nonce',
        'enrollment_signing_public_key',
        'enrollment_signing_fingerprint',
        'server_key_agreement_public_key',
        'trust_mode',
        'invalid_proof_attempts',
        'completion_request_digest',
        'completion_result',
        'pairing_secret_digest',
        'server_receive_key',
        'server_send_key',
        'short_authentication_code',
    ];

    protected $hidden = [
        'protected_server_private_material', 'completion_request_digest', 'completion_result',
        'pairing_secret_digest', 'server_receive_key', 'server_send_key', 'short_authentication_code',
    ];

    protected function casts(): array
    {
        return [
            'expires_at' => 'immutable_datetime',
            'invalid_proof_attempts' => 'integer',
            'server_receive_key' => 'encrypted',
            'server_send_key' => 'encrypted',
            'short_authentication_code' => 'encrypted',
        ];
    }
}
