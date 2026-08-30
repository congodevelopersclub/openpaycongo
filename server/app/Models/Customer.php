<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;

class Customer extends Model
{
    use HasUuids;

    public $incrementing = false;

    protected $keyType = 'string';

    protected $fillable = ['organization_id', 'private_lookup_digest', 'private_lookup_key_version'];

    protected $hidden = ['private_lookup_digest', 'private_lookup_key_version'];
}
