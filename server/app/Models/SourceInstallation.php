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

    protected $fillable = ['organization_id', 'installation_digest', 'installation_lookup_id', 'installation_key_version'];

    protected $hidden = ['installation_digest', 'installation_lookup_id', 'installation_key_version'];
}
