<?php

namespace App\Policies;

use App\Models\Deposit;
use App\Models\User;

final class DepositPolicy
{
    public function view(User $user, Deposit $deposit): bool
    {
        return (bool) $user->is_financial_operator;
    }

    public function correct(User $user, Deposit $deposit): bool
    {
        return (bool) $user->is_financial_operator;
    }
}
