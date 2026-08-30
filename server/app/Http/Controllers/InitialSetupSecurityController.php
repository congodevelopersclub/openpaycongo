<?php

namespace App\Http\Controllers;

use App\Setup\ConfirmRecoveryCodes;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\View\View;

final class InitialSetupSecurityController
{
    public function __invoke(Request $request): View
    {
        return view('setup.security', ['user' => $request->user()]);
    }

    public function acknowledgeRecoveryCodes(Request $request, ConfirmRecoveryCodes $confirm): RedirectResponse
    {
        $request->validate(['recovery_codes_saved' => ['accepted']]);

        $confirm->confirm($request->user());

        return redirect('/setup/security');
    }
}
