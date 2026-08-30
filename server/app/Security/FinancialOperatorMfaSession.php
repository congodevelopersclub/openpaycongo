<?php

namespace App\Security;

use App\Models\User;

interface FinancialOperatorMfaSession
{
    public function assertVerified(User $user): void;
}
