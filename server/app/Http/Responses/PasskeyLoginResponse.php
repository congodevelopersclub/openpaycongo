<?php

namespace App\Http\Responses;

use App\Models\User;
use Illuminate\Contracts\Auth\StatefulGuard;
use Illuminate\Contracts\Support\Responsable;

final class PasskeyLoginResponse implements Responsable
{
    public function __construct(private readonly StatefulGuard $guard) {}

    public function toResponse($request)
    {
        $user = $this->guard->user();

        if (! $user instanceof User || ! $user->is_financial_operator || $user->two_factor_confirmed_at === null) {
            $this->guard->logout();
            $request->session()->forget(['login.id', 'login.remember', 'financial_operator_mfa.user_id']);

            return $request->wantsJson()
                ? response()->json(['redirect' => '/'])
                : redirect('/');
        }

        $this->guard->logout();
        $request->session()->put([
            'login.id' => $user->getKey(),
            'login.remember' => $request->boolean('remember'),
        ]);

        return $request->wantsJson()
            ? response()->json(['two_factor' => true, 'redirect' => route('two-factor.login')])
            : redirect()->route('two-factor.login');
    }
}
