<?php

declare(strict_types=1);

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

final class PairingCompletionReservation extends Model
{
    use HasUuids;

    public $incrementing = false;

    protected $keyType = 'string';

    protected $fillable = ['pairing_intent_id', 'request_digest', 'state', 'lease_expires_at'];

    protected $hidden = ['request_digest'];

    protected function casts(): array
    {
        return ['lease_expires_at' => 'immutable_datetime'];
    }

    /** @return BelongsTo<PairingIntent, $this> */
    public function intent(): BelongsTo
    {
        return $this->belongsTo(PairingIntent::class, 'pairing_intent_id');
    }
}
