<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUuids;

class PrivateLookupAlias extends ImmutableFinancialModel
{
    use HasUuids;

    public $incrementing = false;

    public const UPDATED_AT = null;

    protected $keyType = 'string';

    protected $fillable = ['organization_id', 'purpose', 'digest', 'lookup_id', 'created_at'];

    protected $hidden = ['digest', 'lookup_id'];
}
