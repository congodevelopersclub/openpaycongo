<?php

namespace App\Http\Middleware;

use Illuminate\Http\Request;
use Laravel\Passport\AccessToken;
use Laravel\Passport\Contracts\ScopeAuthorizable;
use Laravel\Passport\Exceptions\AuthenticationException;
use Laravel\Passport\Http\Middleware\CheckToken;
use League\OAuth2\Server\Exception\OAuthServerException;
use Symfony\Bridge\PsrHttpMessage\Factory\PsrHttpFactory;

/** OAuth service authority never comes from a browser session or mobile token. */
final class CheckServiceToken extends CheckToken
{
    protected function validateToken(Request $request): ScopeAuthorizable
    {
        try {
            return AccessToken::fromPsrRequest(
                $this->server->validateAuthenticatedRequest((new PsrHttpFactory)->createRequest($request)),
            );
        } catch (OAuthServerException) {
            throw new AuthenticationException;
        }
    }
}
