<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

final class WalletWebhookDelivery extends Model
{
    use HasUuids;

    public $incrementing = false;

    protected $keyType = 'string';

    protected $fillable = ['webhook_endpoint_id', 'deposit_id', 'event_id', 'body', 'status', 'attempts', 'claimed_at', 'claim_token', 'next_attempt_at', 'delivered_at', 'last_error_code'];

    protected $hidden = ['body', 'claim_token'];

    protected function casts(): array
    {
        return ['attempts' => 'integer', 'claimed_at' => 'immutable_datetime', 'next_attempt_at' => 'immutable_datetime', 'delivered_at' => 'immutable_datetime'];
    }

    /** @return BelongsTo<WebhookEndpoint, $this> */
    public function webhookEndpoint(): BelongsTo
    {
        return $this->belongsTo(WebhookEndpoint::class);
    }
}
