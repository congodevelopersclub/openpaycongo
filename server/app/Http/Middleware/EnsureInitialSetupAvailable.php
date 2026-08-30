<?php

namespace App\Http\Middleware;

use App\Setup\InitialSetupAvailability;
use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

final class EnsureInitialSetupAvailable
{
    public function __construct(private readonly InitialSetupAvailability $availability) {}

    /**
     * @param  Closure(Request): Response  $next
     */
    public function handle(Request $request, Closure $next): Response
    {
        abort_unless($this->availability->isAvailable(), 404);

        return $next($request);
    }
}
