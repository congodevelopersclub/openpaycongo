<?php

declare(strict_types=1);

namespace App\Http\Middleware;

use App\Models\User;
use App\Security\FinancialOperatorMfaSession;
use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Str;
use Symfony\Component\HttpFoundation\Response;

final class RequireVerifiedPairingIntentIssuer
{
    public function __construct(
        private readonly FinancialOperatorMfaSession $mfa,
    ) {}

    public function handle(Request $request, Closure $next): Response
    {
        $user = $request->user();

        abort_unless(
            $user instanceof User
                && $user->is_financial_operator
                && is_string($user->organization_id)
                && Str::isUuid($user->organization_id)
                && strtolower($user->organization_id) === $user->organization_id,
            403,
        );

        $this->mfa->assertVerified($user);

        return $next($request);
    }
}
