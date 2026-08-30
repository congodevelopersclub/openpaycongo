<?php

namespace App\Listeners;

use App\Security\EstablishFinancialOperatorMfaSession as EstablishSession;
use Illuminate\Contracts\Session\Session;
use Laravel\Fortify\Events\ValidTwoFactorAuthenticationCodeProvided;

final class EstablishFinancialOperatorMfaSession
{
    public function __construct(
        private readonly EstablishSession $establishSession,
        private readonly Session $session,
    ) {}

    public function handle(ValidTwoFactorAuthenticationCodeProvided $event): void
    {
        $this->establishSession->establish($event->user, $this->session);
    }
}
