<?php

declare(strict_types=1);

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

final class PreventPairingIntentCaching
{
    public function handle(Request $request, Closure $next): Response
    {
        $response = $next($request);

        if ($request->routeIs('filament.operations.pages.issue-pairing-intent', 'default-livewire.update')) {
            $response->headers->set('Cache-Control', 'private, no-store');
        }

        return $response;
    }
}
