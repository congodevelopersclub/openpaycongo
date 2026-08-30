<?php

namespace App\Http\Middleware;

use App\Models\Deposit;
use App\Models\User;
use App\Security\FinancialOperatorMfaSession;
use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

final class RequireFinancialOperatorMfa
{
    public function handle(Request $request, Closure $next): Response
    {
        $user = $request->user();
        abort_unless($user instanceof User && $user->can('viewAny', Deposit::class), 404);

        app(FinancialOperatorMfaSession::class)->assertVerified($user);

        return $next($request);
    }
}
