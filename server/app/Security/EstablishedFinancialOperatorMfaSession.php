<?php

namespace App\Security;

use App\Models\User;
use Illuminate\Auth\Access\AuthorizationException;
use Illuminate\Contracts\Session\Session;

final class EstablishedFinancialOperatorMfaSession implements FinancialOperatorMfaSession
{
    public function __construct(
        private readonly Session $session,
    ) {}

    public function assertVerified(User $user): void
    {
        $isVerified = $user->is_financial_operator
            && $user->two_factor_confirmed_at !== null
            && $user->recovery_codes_confirmed_at !== null
            && auth()->id() === $user->getAuthIdentifier()
            && $this->session->get('financial_operator_mfa.user_id') === $user->getAuthIdentifier();

        if (! $isVerified) {
            throw new AuthorizationException('A verified financial operator MFA session is required.');
        }
    }
}
