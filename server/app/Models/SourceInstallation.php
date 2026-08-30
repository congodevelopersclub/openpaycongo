<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;

class SourceInstallation extends Model
{
    use HasUuids;

    public $incrementing = false;

    protected $keyType = 'string';

    protected $fillable = ['organization_id', 'installation_digest', 'installation_lookup_id', 'installation_key_version'];

    protected $hidden = ['installation_digest', 'installation_lookup_id', 'installation_key_version'];
}
