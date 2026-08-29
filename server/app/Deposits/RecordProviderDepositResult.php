<?php

namespace App\Deposits;

use App\Models\Deposit;

final readonly class RecordProviderDepositResult
{
    public function __construct(public RecordResult $outcome, public Deposit $deposit) {}
}
