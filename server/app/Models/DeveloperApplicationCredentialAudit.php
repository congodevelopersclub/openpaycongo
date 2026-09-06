<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

final class DeveloperApplicationCredentialAudit extends Model
{
    use HasUuids;

    protected $keyType = 'string';

    public $incrementing = false;

    public $timestamps = false;

    protected $guarded = [];

    protected function casts(): array
    {
        return [
            'scopes' => 'array',
            'created_at' => 'datetime',
        ];
    }

    /** @return BelongsTo<DeveloperApplication, $this> */
    public function developerApplication(): BelongsTo
    {
        return $this->belongsTo(DeveloperApplication::class);
    }
}
