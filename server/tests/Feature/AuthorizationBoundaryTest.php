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
        ];
        $signedFrameworkRoutes = [
            'GET|HEAD storage/{path}' => 'storage.local',
            'PUT storage/{path}' => 'storage.local.upload',
        ];
        $runtimeRouteCount = 0;

        self::assertCount(5, $anonymousRoutes);
        self::assertCount(2, $signedFrameworkRoutes);

        foreach (app('router')->getRoutes()->getRoutes() as $route) {
            $runtimeRouteCount++;
            $signature = implode('|', $route->methods()).' '.$route->uri();

            if (in_array($signature, $anonymousRoutes, true)) {
                continue;
            }

            if (array_key_exists($signature, $signedFrameworkRoutes)) {
                self::assertSame(
                    $signedFrameworkRoutes[$signature],
                    $route->getName(),
                    "Framework route [{$signature}] must retain its explicit signed-route inventory entry.",
                );

                continue;
            }

            self::assertTrue(
                collect($route->gatherMiddleware())->contains(
                    static fn (string $middleware): bool => str_starts_with($middleware, 'auth') || str_starts_with($middleware, 'can:'),
                ),
                "Route [{$signature}] is neither in the reviewed anonymous inventory nor protected by authorization middleware.",
            );
        }

        self::assertSame(7, $runtimeRouteCount, 'Runtime route changes require an explicit authorization-boundary inventory review.');
    }

    public function test_unsigned_framework_storage_routes_are_rejected(): void
    {
        $this->get('/storage/not-signed')->assertForbidden();
        $this->put('/storage/not-signed?upload=true')->assertForbidden();
    }
}
