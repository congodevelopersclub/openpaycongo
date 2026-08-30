<?php

namespace App\Security;

use App\Models\User;
use Illuminate\Auth\Access\AuthorizationException;

final class UnavailableFinancialOperatorMfaSession implements FinancialOperatorMfaSession
{
    public function assertVerified(User $user): void
    {
        throw new AuthorizationException('Financial operator MFA verification is not available.');
    }
}
