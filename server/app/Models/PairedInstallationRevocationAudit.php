<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;

final class PairedInstallationRevocationAudit extends Model
{
    use HasUuids;

    protected $keyType = 'string';

    public $incrementing = false;

    public $timestamps = false;

    protected $fillable = [
        'organization_id',
        'source_installation_id',
        'actor_user_id',
        'actor_user_identifier',
        'action',
    ];

    protected function casts(): array
    {
        return ['created_at' => 'immutable_datetime'];
    }
}
