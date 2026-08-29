<?php

namespace App\Deposits;

use App\Models\Deposit;

final readonly class ReverseProviderDepositResult
{
    public function __construct(public ReversalResult $outcome, public Deposit $deposit) {}
}
