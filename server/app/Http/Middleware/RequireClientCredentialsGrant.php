<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

final class RequireClientCredentialsGrant
{
    /** @param Closure(Request): Response $next */
    public function handle(Request $request, Closure $next): Response
    {
        if ($request->input('grant_type') !== 'client_credentials') {
            return response()->json([
                'error' => 'unsupported_grant_type',
                'error_description' => 'Only the client_credentials grant is supported.',
            ], Response::HTTP_BAD_REQUEST);
        }

        return $next($request);
    }
}
