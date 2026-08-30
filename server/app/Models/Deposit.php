<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;

class Deposit extends ImmutableFinancialModel
{
    use HasUuids;

    public $incrementing = false;

    protected $keyType = 'string';

    protected $fillable = [
        'organization_id', 'customer_id', 'source_installation_id', 'reverses_deposit_id', 'kind',
        'amount_minor', 'currency', 'provider_reference', 'provider_reference_digest', 'provider_reference_lookup_id', 'provider_reference_key_version', 'provider_occurred_at',
        'received_at', 'sender_identifier', 'receiver_identifier', 'idempotency_digest', 'idempotency_key_version',
    ];

    protected $hidden = [
        'provider_reference', 'provider_reference_digest', 'provider_reference_lookup_id', 'provider_reference_key_version', 'sender_identifier', 'receiver_identifier', 'idempotency_digest', 'idempotency_key_version',
    ];

    protected function casts(): array
    {
        return [
            'provider_reference' => 'encrypted',
            'provider_occurred_at' => 'immutable_datetime',
            'received_at' => 'immutable_datetime',
            'sender_identifier' => 'encrypted',
            'receiver_identifier' => 'encrypted',
        ];
    }

    /** @return BelongsTo<Customer, $this> */
    public function customer(): BelongsTo
    {
        return $this->belongsTo(Customer::class);
    }

    /** @return BelongsTo<SourceInstallation, $this> */
    public function sourceInstallation(): BelongsTo
    {
        return $this->belongsTo(SourceInstallation::class);
    }

    /** @return BelongsTo<Deposit, $this> */
    public function reversedDeposit(): BelongsTo
    {
        return $this->belongsTo(self::class, 'reverses_deposit_id');
    }

    /** @return HasMany<LedgerEntry, $this> */
    public function ledgerEntries(): HasMany
    {
        return $this->hasMany(LedgerEntry::class);
    }
}
