<?php

namespace Tests\Feature;

use App\Http\Middleware\RequireFinancialOperatorMfa;
use Illuminate\Auth\Middleware\Authenticate;
use Illuminate\Auth\Middleware\Authorize;
use Illuminate\Foundation\Http\Middleware\TrimStrings;
use Laravel\Passport\Http\Middleware\CheckToken;
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
            'GET|HEAD login',
            'POST login',
            'GET|HEAD two-factor-challenge',
            'POST two-factor-challenge',
            'GET|HEAD passkeys/login/options',
            'POST passkeys/login',
            // This boundary returns 404 before request validation after initial setup is claimed.
            'GET|HEAD setup',
            'POST setup',
        ];
        $signedFrameworkRoutes = [
            'GET|HEAD storage/{path}' => 'storage.local',
            'PUT storage/{path}' => 'storage.local.upload',
            'GET|HEAD filament/exports/{export}/download' => 'filament.exports.download',
            'GET|HEAD filament/imports/{import}/failed-rows/download' => 'filament.imports.failed-rows.download',
        ];
        // Passport validates the confidential client credentials in the token exchange itself.
        // It is intentionally reviewed separately from generic anonymous routes.
        $confidentialClientTokenExchangeRoutes = [
            'POST oauth/token' => 'passport.token',
        ];
        $authorizedRoutes = [
            'POST v1/pairing/intents' => ['web', 'auth', 'pairing.issuer', 'throttle:pairing-intents'],
        ];
        $runtimeRouteCount = 0;

        self::assertCount(13, $anonymousRoutes);
        self::assertCount(4, $signedFrameworkRoutes);
        self::assertCount(1, $confidentialClientTokenExchangeRoutes);
        self::assertCount(1, $authorizedRoutes);

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

            if (array_key_exists($signature, $confidentialClientTokenExchangeRoutes)) {
                self::assertSame(
                    $confidentialClientTokenExchangeRoutes[$signature],
                    $route->getName(),
                    "Token exchange [{$signature}] must retain its explicit confidential-client inventory entry.",
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

        self::assertSame(44, $runtimeRouteCount, 'Runtime route changes require an explicit authorization-boundary inventory review.');
    }

    public function test_operations_routes_require_mfa_without_capturing_the_global_livewire_update_boundary(): void
    {
        $routes = collect(app('router')->getRoutes()->getRoutes());
        $livewireUpdate = $routes->first(static fn ($route): bool => $route->getName() === 'default-livewire.update');
        $operationsRoutes = $routes->filter(static fn ($route): bool => str_starts_with($route->uri(), 'operations'));

        self::assertNotNull($livewireUpdate);
        self::assertNotContains(RequireFinancialOperatorMfa::class, app('router')->gatherRouteMiddleware($livewireUpdate));
        self::assertCount(4, $operationsRoutes);

        foreach ($operationsRoutes as $route) {
            self::assertContains(RequireFinancialOperatorMfa::class, app('router')->gatherRouteMiddleware($route));
        }
    }

    public function test_passport_token_exchange_is_reviewed_as_a_confidential_client_boundary(): void
    {
        $route = collect(app('router')->getRoutes()->getRoutes())
            ->first(static fn ($route): bool => implode('|', $route->methods()).' '.$route->uri() === 'POST oauth/token');

        self::assertNotNull($route);
        self::assertSame('passport.token', $route->getName());
        self::assertStringContainsString('AccessTokenController', (string) $route->getAction('controller'));
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
        self::assertTrue($this->isExpectedBoundaryMiddleware(CheckToken::class.':payment-requests:read'));
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
        $isServiceTokenForm = $middleware === CheckToken::class
            || str_starts_with($middleware, CheckToken::class.':');

        if (! $isAuthenticationForm && ! $isAuthorizationForm && ! $isServiceTokenForm) {
            return false;
        }

        return collect(app('router')->resolveMiddleware([$middleware]))
            ->map(static fn (string $resolved): string => explode(':', $resolved, 2)[0])
            ->contains(static fn (string $resolved): bool => in_array($resolved, [Authenticate::class, Authorize::class, CheckToken::class], true));
    }
}
