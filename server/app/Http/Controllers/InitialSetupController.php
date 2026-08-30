<?php

namespace App\Http\Controllers;

use App\Http\Requests\ClaimInitialSetupRequest;
use App\Setup\ClaimInitialSetup;
use App\Setup\InitialSetupAvailability;
use Illuminate\Http\RedirectResponse;
use Illuminate\Support\Facades\Auth;
use Illuminate\View\View;

final class InitialSetupController
{
    public function __invoke(InitialSetupAvailability $availability): View
    {
        abort_unless($availability->isAvailable(), 404);

        return view('setup.initial');
    }

    public function store(ClaimInitialSetupRequest $request, ClaimInitialSetup $claim): RedirectResponse
    {
        $user = $claim->claim($request->safe()->only(['username', 'name', 'email', 'password']));

        Auth::login($user);
        $request->session()->regenerate();

        return redirect('/setup/security');
    }
}
