<?php

declare(strict_types=1);

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

final class ApprovedSmsParserRelease extends Model
{
    protected $primaryKey = 'release_id';

    public $incrementing = false;

    protected $keyType = 'string';

    protected $fillable = [
        'release_id', 'provider', 'sender', 'template', 'pattern_version', 'approved_at', 'expires_at', 'signature', 'signing_public_key',
    ];

    protected function casts(): array
    {
        return [
            'pattern_version' => 'integer',
            'approved_at' => 'immutable_datetime',
            'expires_at' => 'immutable_datetime',
        ];
    }
}
