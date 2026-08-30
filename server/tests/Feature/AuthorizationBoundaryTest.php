<?php

namespace Tests\Feature;

use Tests\TestCase;

final class AuthorizationBoundaryTest extends TestCase
{
    public function test_every_runtime_route_is_reviewed_as_public_or_authorized(): void
    {
        $anonymousRoutes = [
            'GET|HEAD healthz',
            'GET|HEAD readyz',
            'GET|HEAD version',
            'GET|HEAD up', // Explicitly retained by bootstrap/app.php.
            'GET|HEAD /',
            'GET|HEAD storage/{path}',
            'PUT storage/{path}',
        ];

        foreach (app('router')->getRoutes()->getRoutes() as $route) {
            $signature = implode('|', $route->methods()).' '.$route->uri();

            if (in_array($signature, $anonymousRoutes, true)) {
                continue;
            }

            self::assertTrue(
                collect($route->gatherMiddleware())->contains(
                    static fn (string $middleware): bool => str_starts_with($middleware, 'auth') || str_starts_with($middleware, 'can:'),
                ),
                "Route [{$signature}] is neither in the reviewed anonymous inventory nor protected by authorization middleware.",
            );
        }
    }
}
