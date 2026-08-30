<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class LedgerEntry extends ImmutableFinancialModel
{
    use HasUuids;

    public $incrementing = false;

    protected $keyType = 'string';

    protected $fillable = ['deposit_id', 'organization_id', 'reverses_ledger_entry_id', 'account', 'debit_minor', 'credit_minor', 'currency', 'recorded_at'];

    protected function casts(): array
    {
        return ['recorded_at' => 'immutable_datetime'];
    }

    /** @return BelongsTo<Deposit, $this> */
    public function deposit(): BelongsTo
    {
        return $this->belongsTo(Deposit::class);
    }

    /** @return BelongsTo<LedgerEntry, $this> */
    public function reversesLedgerEntry(): BelongsTo
    {
        return $this->belongsTo(self::class, 'reverses_ledger_entry_id');
    }
}
