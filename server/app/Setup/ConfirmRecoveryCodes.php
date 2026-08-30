<?php

namespace App\Setup;

use App\Models\User;
use Illuminate\Auth\Access\AuthorizationException;

final class ConfirmRecoveryCodes
{
    public function __construct(private readonly RecordSecurityAudit $audit) {}

    public function confirm(User $user): void
    {
        if ($user->two_factor_confirmed_at === null || $user->two_factor_recovery_codes === null) {
            throw new AuthorizationException('Confirmed two-factor recovery codes are required.');
        }

        $user->forceFill(['recovery_codes_confirmed_at' => now()])->save();
        $this->audit->record($user, 'recovery_codes_acknowledged');
    }
}
