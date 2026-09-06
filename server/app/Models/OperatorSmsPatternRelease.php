<?php

declare(strict_types=1);

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** A signed immutable release which a mobile client may verify and activate. */
final class OperatorSmsPatternRelease extends Model
{
    use HasUuids;

    public $timestamps = false;

    protected $keyType = 'string';

    public $incrementing = false;

    protected $fillable = [
        'operator_sms_pattern_proposal_id',
        'organization_id',
        'provider',
        'sender',
        'pattern_version',
        'encoded_release',
        'expires_at',
        'issued_by_user_id',
        'issued_at',
    ];

    protected function casts(): array
    {
        return [
            'expires_at' => 'immutable_datetime',
            'issued_at' => 'immutable_datetime',
        ];
    }

    /** @return BelongsTo<OperatorSmsPatternProposal, $this> */
    public function proposal(): BelongsTo
    {
        return $this->belongsTo(OperatorSmsPatternProposal::class, 'operator_sms_pattern_proposal_id');
    }

    /** @return BelongsTo<User, $this> */
    public function issuedBy(): BelongsTo
    {
        return $this->belongsTo(User::class, 'issued_by_user_id');
    }
}
