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
        'state',
        'expires_at',
        'protected_server_private_material',
    ];

    protected $hidden = ['protected_server_private_material'];

    protected function casts(): array
    {
        return ['expires_at' => 'immutable_datetime'];
    }
}
