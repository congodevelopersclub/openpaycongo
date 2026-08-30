<?php

namespace App\Providers;

use App\Listeners\EstablishFinancialOperatorMfaSession;
use Illuminate\Cache\RateLimiting\Limit;
use Illuminate\Support\Facades\Event;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Support\ServiceProvider;
use Illuminate\Support\Str;
use Laravel\Fortify\Fortify;
use Laravel\Fortify\Events\ValidTwoFactorAuthenticationCodeProvided;

final class FortifyServiceProvider extends ServiceProvider
{
    public function boot(): void
    {
        Event::listen(ValidTwoFactorAuthenticationCodeProvided::class, EstablishFinancialOperatorMfaSession::class);

        Fortify::loginView(static fn () => view('auth.login'));
        Fortify::twoFactorChallengeView(static fn () => view('auth.two-factor-challenge'));
        Fortify::confirmPasswordView(static fn () => view('auth.confirm-password'));

        RateLimiter::for('login', static function (Request $request): Limit {
            return Limit::perMinute(5)->by(
                Str::transliterate(Str::lower((string) $request->input(Fortify::username())).'|'.$request->ip()),
            );
        });

        RateLimiter::for('two-factor', static function (Request $request): Limit {
            return Limit::perMinute(5)->by((string) $request->session()->get('login.id'));
        });

        RateLimiter::for('passkeys', static function (Request $request): Limit {
            return Limit::perMinute(10)->by(
                ((string) $request->input('credential.id') ?: $request->session()->getId()).'|'.$request->ip(),
            );
        });
    }
}
