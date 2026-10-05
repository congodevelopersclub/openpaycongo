<?php

declare(strict_types=1);

namespace App\Models;

use Carbon\CarbonImmutable;
use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use LogicException;

/** @property CarbonImmutable|null $reviewed_at */
final class OperatorSmsPatternProposal extends Model
{
    use HasUuids;

    protected $keyType = 'string';

    public $incrementing = false;

    protected $fillable = [
        'organization_id',
        'provider',
        'sender',
        'template',
        'template_sha256',
        'proposal_revision',
        'model',
        'status',
        'reviewed_by_user_id',
        'reviewed_at',
    ];

    protected static function booted(): void
    {
        self::updating(static function (self $proposal): void {
            if ($proposal->getOriginal('status') === 'approved') {
                throw new LogicException('Approved parser proposals are immutable.');
            }
        });

        self::deleting(static function (self $proposal): void {
            if ($proposal->status === 'approved') {
                throw new LogicException('Approved parser proposals are immutable.');
            }
        });
    }

    protected function casts(): array
    {
        return [
            'proposal_revision' => 'integer',
            'reviewed_at' => 'immutable_datetime',
        ];
    }

    /** @return BelongsTo<User, $this> */
    public function reviewedBy(): BelongsTo
    {
        return $this->belongsTo(User::class, 'reviewed_by_user_id');
    }

    public function isActivated(): bool
    {
        return false;
    }
}
