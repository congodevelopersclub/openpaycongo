<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;

class Customer extends Model
{
    use HasUuids;

    public $incrementing = false;

    protected $keyType = 'string';

    protected $fillable = [
        'organization_id', 'private_lookup_digest', 'private_lookup_id', 'private_lookup_key_version',
        'name', 'address', 'phone', 'email',
    ];

    protected $hidden = [
        'private_lookup_digest', 'private_lookup_id', 'private_lookup_key_version',
        'name', 'address', 'phone', 'email',
    ];

    protected function casts(): array
    {
        return [
            'name' => 'encrypted',
            'address' => 'encrypted',
            'phone' => 'encrypted',
            'email' => 'encrypted',
        ];
    }
}
