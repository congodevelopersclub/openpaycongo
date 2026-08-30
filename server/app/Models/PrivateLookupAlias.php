<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;

class PrivateLookupAlias extends Model
{
    use HasUuids;

    public $incrementing = false;

    public $timestamps = false;

    protected $keyType = 'string';

    protected $fillable = ['organization_id', 'purpose', 'digest', 'lookup_id', 'created_at'];

    protected $hidden = ['digest', 'lookup_id'];
}
