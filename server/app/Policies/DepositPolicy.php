<?php

namespace App\Policies;

use App\Models\Deposit;
use App\Models\User;

final class DepositPolicy
{
    public function viewAny(User $user): bool
    {
        return $this->isOperatorInOrganization($user);
    }

    public function view(User $user, Deposit $deposit): bool
    {
        return $this->isOperatorInOrganization($user)
            && $user->organization_id === $deposit->organization_id;
    }

    public function correct(User $user, Deposit $deposit): bool
    {
        return $this->isOperatorInOrganization($user)
            && $user->organization_id === $deposit->organization_id;
    }

    private function isOperatorInOrganization(User $user): bool
    {
        return (bool) $user->is_financial_operator
            && is_string($user->organization_id)
            && $user->organization_id !== '';
    }
}
