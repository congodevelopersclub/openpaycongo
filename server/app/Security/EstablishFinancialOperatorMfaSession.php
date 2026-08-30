<?php

namespace App\Security;

use App\Models\User;
use Illuminate\Contracts\Session\Session;

final class EstablishFinancialOperatorMfaSession
{
    public function establish(User $user, Session $session): void
    {
        if (! $user->is_financial_operator || $user->two_factor_confirmed_at === null || $user->recovery_codes_confirmed_at === null) {
            return;
        }

        $session->put('financial_operator_mfa.user_id', $user->getAuthIdentifier());
    }
}
