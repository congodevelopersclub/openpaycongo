<?php

namespace App\Listeners;

use App\Setup\RecordSecurityAudit;
use Laravel\Fortify\Events\RecoveryCodesGenerated;
use Laravel\Fortify\Events\TwoFactorAuthenticationEnabled;

final class InvalidateRecoveryCodeAcknowledgement
{
    public function __construct(private readonly RecordSecurityAudit $audit) {}

    public function handle(RecoveryCodesGenerated|TwoFactorAuthenticationEnabled $event): void
    {
        $event->user->forceFill(['recovery_codes_confirmed_at' => null])->save();
        $this->audit->record($event->user, 'recovery_codes_generated');
    }
}
