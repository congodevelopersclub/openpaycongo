<?php

declare(strict_types=1);

namespace App\Models;

use Carbon\CarbonImmutable;
use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use LogicException;

/**
 * A signed immutable release which a mobile client may verify and activate.
 *
 * @property CarbonImmutable $expires_at
 * @property CarbonImmutable $issued_at
 */
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
        'parser_release_digest',
        'encoded_release',
        'expires_at',
        'issued_by_user_id',
        'issued_at',
    ];

    protected static function booted(): void
    {
        self::updating(static function (self $release): void {
            throw new LogicException('Signed parser releases are immutable.');
        });
        self::deleting(static function (self $release): void {
            throw new LogicException('Signed parser releases are immutable.');
        });
    }

    protected function casts(): array
    {
        return [
            'pattern_version' => 'integer',
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
