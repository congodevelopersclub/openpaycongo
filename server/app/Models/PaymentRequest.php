<?php

namespace App\Models;

use App\PaymentRequests\PaymentRequestStatus;
use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class PaymentRequest extends Model
{
    use HasUuids;

    public $incrementing = false;

    protected $keyType = 'string';

    protected $fillable = [
        'customer_id', 'idempotency_digest', 'currency', 'amount_minor', 'remaining_minor', 'status', 'expires_at', 'charged_at',
    ];

    protected $hidden = ['idempotency_digest'];

    protected function casts(): array
    {
        return [
            'status' => PaymentRequestStatus::class,
            'expires_at' => 'immutable_datetime',
            'charged_at' => 'immutable_datetime',
        ];
    }

    /** @return BelongsTo<Customer, $this> */
    public function customer(): BelongsTo
    {
        return $this->belongsTo(Customer::class);
    }
}
