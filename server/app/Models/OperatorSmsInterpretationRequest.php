<?php

declare(strict_types=1);

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/**
 * Encrypted evidence retained only for a user-requested, developer-governed
 * pattern analysis. It is not an accepted payment and is hidden from model
 * serialization to keep it out of ordinary logs and telemetry.
 */
final class OperatorSmsInterpretationRequest extends Model
{
    use HasUuids;

    protected $keyType = 'string';

    public $incrementing = false;

    protected $fillable = [
        'organization_id',
        'source_installation_id',
        'sms_record_id',
        'sender',
        'protected_sms_body',
        'received_at',
        'expires_at',
    ];

    protected $hidden = ['protected_sms_body'];

    protected function casts(): array
    {
        return [
            'protected_sms_body' => 'encrypted',
            'received_at' => 'immutable_datetime',
            'expires_at' => 'immutable_datetime',
        ];
    }

    /** @return BelongsTo<SourceInstallation, $this> */
    public function sourceInstallation(): BelongsTo
    {
        return $this->belongsTo(SourceInstallation::class);
    }
}
