<?php

namespace App\Http\Controllers;

use App\Setup\ConfirmRecoveryCodes;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\View\View;
use Laravel\Fortify\Features;

final class InitialSetupSecurityController
{
    public function __invoke(Request $request): View
    {
        $user = $request->user();

        return view('setup.security', [
            'user' => $user,
            'passkeys' => Features::canManagePasskeys() && $user->two_factor_confirmed_at !== null
                ? $user->passkeys()->orderByDesc('created_at')->get(['id', 'name', 'last_used_at'])
                : collect(),
            'passkeysAvailable' => Features::canManagePasskeys() && $user->two_factor_confirmed_at !== null,
        ]);
    }

    public function acknowledgeRecoveryCodes(Request $request, ConfirmRecoveryCodes $confirm): RedirectResponse
    {
        $request->validate(['recovery_codes_saved' => ['accepted']]);

        $confirm->confirm($request->user());

        return redirect('/setup/security');
    }
}
