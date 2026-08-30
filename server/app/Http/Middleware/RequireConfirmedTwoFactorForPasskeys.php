<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

final class RequireConfirmedTwoFactorForPasskeys
{
    /**
     * @param  Closure(Request): Response  $next
     */
    public function handle(Request $request, Closure $next): Response
    {
        if (! in_array($request->route()?->getName(), [
            'passkey.registration-options',
            'passkey.store',
            'passkey.destroy',
        ], true)) {
            return $next($request);
        }

        if ($request->user()?->two_factor_confirmed_at === null) {
            abort(403);
        }

        return $next($request);
    }
}
