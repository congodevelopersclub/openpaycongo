<?php

namespace App\Http\Middleware;

use App\Models\DeveloperApplication;
use Closure;
use Illuminate\Http\Request;
use Laravel\Passport\AccessToken;
use Laravel\Passport\Exceptions\AuthenticationException;
use League\OAuth2\Server\Exception\OAuthServerException;
use League\OAuth2\Server\ResourceServer;
use Symfony\Bridge\PsrHttpMessage\Factory\PsrHttpFactory;
use Symfony\Component\HttpFoundation\Response;

final class ResolveDeveloperApplication
{
    public function __construct(private readonly ResourceServer $server) {}

    /** @param Closure(Request): Response $next */
    public function handle(Request $request, Closure $next): Response
    {
        try {
            $accessToken = AccessToken::fromPsrRequest(
                $this->server->validateAuthenticatedRequest((new PsrHttpFactory)->createRequest($request)),
            );
        } catch (OAuthServerException) {
            throw new AuthenticationException;
        }

        $application = DeveloperApplication::query()
            ->where('oauth_client_id', (string) $accessToken->oauth_client_id)
            ->whereHas('oauthClient', static fn ($query) => $query->where('revoked', false))
            ->first();

        if ($application === null) {
            throw new AuthenticationException;
        }

        $request->attributes->set(DeveloperApplication::class, $application);

        return $next($request);
    }
}
