<?php

declare(strict_types=1);

namespace App\Http\Middleware;

use App\Models\SourceInstallation;
use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

final class RequireAcknowledgedMobileActivation
{
    public function handle(Request $request, Closure $next): Response
    {
        /** @var SourceInstallation $installation */
        $installation = $request->user('mobile');

        if ($installation->revoked_at !== null || ($installation->pairing_intent_id !== null && $installation->activation_acknowledged_at === null)) {
            return response()->json(['code' => 'mobile_envelope_unavailable'], 404, ['Cache-Control' => 'no-store, private']);
        }

        return $next($request);
    }
}
