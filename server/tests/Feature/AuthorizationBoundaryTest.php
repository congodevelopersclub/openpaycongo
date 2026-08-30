<?php

namespace Tests\Feature;

use App\Http\Middleware\RequireFinancialOperatorMfa;
use Illuminate\Auth\Middleware\Authenticate;
use Illuminate\Auth\Middleware\Authorize;
use Illuminate\Foundation\Http\Middleware\TrimStrings;
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
            'GET|HEAD filament/exports/{export}/download' => 'filament.exports.download',
            'GET|HEAD filament/imports/{import}/failed-rows/download' => 'filament.imports.failed-rows.download',
        ];
        $authorizedRoutes = [];
        $runtimeRouteCount = 0;

        self::assertCount(5, $anonymousRoutes);
        self::assertCount(4, $signedFrameworkRoutes);
        self::assertCount(0, $authorizedRoutes);

        foreach (app('router')->getRoutes()->getRoutes() as $route) {
            $signature = implode('|', $route->methods()).' '.$route->uri();

            if (app()->environment('testing') && preg_match('#^(?:GET\|HEAD|POST) livewire-[a-z0-9]+/#', $signature) === 1) {
                continue;
            }

            $runtimeRouteCount++;

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

            if (array_key_exists($signature, $authorizedRoutes)) {
                self::assertSame($authorizedRoutes[$signature], array_values(array_intersect($authorizedRoutes[$signature], $route->middleware())));

                continue;
            }

            self::assertTrue(
                collect(app('router')->gatherRouteMiddleware($route))->contains(fn (string $middleware): bool => $this->isExpectedBoundaryMiddleware($middleware)),
                "Route [{$signature}] is neither in the reviewed anonymous inventory nor protected by authorization middleware.",
            );
        }

        self::assertSame(10, $runtimeRouteCount, 'Runtime route changes require an explicit authorization-boundary inventory review.');
    }

    public function test_lookalike_middleware_aliases_do_not_count_as_authorization(): void
    {
        $router = app('router');
        $router->aliasMiddleware('auth', Authenticate::class);
        $router->aliasMiddleware('can', Authorize::class);

        self::assertTrue($this->isExpectedBoundaryMiddleware('auth'));
        self::assertTrue($this->isExpectedBoundaryMiddleware('auth:sanctum'));
        self::assertTrue($this->isExpectedBoundaryMiddleware(Authenticate::class));
        self::assertTrue($this->isExpectedBoundaryMiddleware('can:view,deposit'));
        self::assertTrue($this->isExpectedBoundaryMiddleware(Authorize::class));
        self::assertFalse($this->isExpectedBoundaryMiddleware('auth.optional'));
        self::assertFalse($this->isExpectedBoundaryMiddleware('authorize-anything'));

        $router->aliasMiddleware('auth', TrimStrings::class);

        try {
            self::assertFalse($this->isExpectedBoundaryMiddleware('auth'));
        } finally {
            $router->aliasMiddleware('auth', Authenticate::class);
        }
    }

    public function test_unsigned_framework_storage_routes_are_rejected(): void
    {
        $this->get('/storage/not-signed')->assertForbidden();
        $this->put('/storage/not-signed?upload=true')->assertForbidden();
    }

    public function test_excluded_authentication_middleware_does_not_count_as_authorization(): void
    {
        $router = app('router');
        $router->aliasMiddleware('auth', Authenticate::class);
        $route = $router->get('/security-gate-excluded-auth-fixture', static fn () => response()->noContent())
            ->middleware('auth')
            ->withoutMiddleware('auth');

        self::assertFalse(
            collect($router->gatherRouteMiddleware($route))
                ->contains(fn (string $middleware): bool => $this->isExpectedBoundaryMiddleware($middleware)),
        );
    }

    private function isExpectedBoundaryMiddleware(string $middleware): bool
    {
        if ($middleware === RequireFinancialOperatorMfa::class) {
            return true;
        }

        $isAuthenticationForm = $middleware === 'auth'
            || str_starts_with($middleware, 'auth:')
            || $middleware === Authenticate::class
            || str_starts_with($middleware, Authenticate::class.':');
        $isAuthorizationForm = str_starts_with($middleware, 'can:')
            || $middleware === Authorize::class
            || str_starts_with($middleware, Authorize::class.':');

        if (! $isAuthenticationForm && ! $isAuthorizationForm) {
            return false;
        }

        return collect(app('router')->resolveMiddleware([$middleware]))
            ->map(static fn (string $resolved): string => explode(':', $resolved, 2)[0])
            ->contains(static fn (string $resolved): bool => $resolved === Authenticate::class || $resolved === Authorize::class);
    }
}
