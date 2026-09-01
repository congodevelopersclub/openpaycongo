<?php

namespace App\Models;

use Illuminate\Auth\Authenticatable;
use Illuminate\Contracts\Auth\Authenticatable as AuthenticatableContract;
use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;
use Laravel\Sanctum\HasApiTokens;

class SourceInstallation extends Model implements AuthenticatableContract
{
    use Authenticatable, HasApiTokens, HasUuids;

    public $incrementing = false;

    protected $keyType = 'string';

    protected $fillable = ['organization_id', 'installation_digest', 'installation_lookup_id', 'installation_key_version', 'mobile_receive_key', 'mobile_send_key', 'mobile_replay_counter', 'pairing_intent_id', 'activation_nonce', 'activation_ciphertext'];

    protected $hidden = ['installation_digest', 'installation_lookup_id', 'installation_key_version', 'mobile_receive_key', 'mobile_send_key', 'pairing_intent_id', 'activation_nonce', 'activation_ciphertext'];

    protected function casts(): array
    {
        return [
            'mobile_receive_key' => 'encrypted',
            'mobile_send_key' => 'encrypted',
            'activation_nonce' => 'encrypted',
            'activation_ciphertext' => 'encrypted',
            'mobile_replay_counter' => 'integer',
        ];
    }
}
