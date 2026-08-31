<?php

use App\Http\Middleware\RequireConfirmedTwoFactorForPasskeys;
use Illuminate\Auth\Access\AuthorizationException;
use Illuminate\Auth\AuthenticationException;
use Illuminate\Foundation\Application;
use Illuminate\Foundation\Configuration\Exceptions;
use Illuminate\Foundation\Configuration\Middleware;
use Illuminate\Http\Request;
use Laravel\Sanctum\Http\Middleware\CheckAbilities;
use Laravel\Sanctum\Http\Middleware\CheckForAnyAbility;
use Symfony\Component\HttpKernel\Exception\HttpExceptionInterface;

$trustedProxyCidrs = preg_split(
    '/\\s+/',
    (string) env('OPENPAY_TRUSTED_PROXY_CIDRS', '127.0.0.1/32'),
    -1,
    PREG_SPLIT_NO_EMPTY,
);

return Application::configure(basePath: dirname(__DIR__))
    ->withRouting(
        api: __DIR__.'/../routes/api.php',
        apiPrefix: '',
        web: __DIR__.'/../routes/web.php',
        commands: __DIR__.'/../routes/console.php',
        health: '/up',
    )
    ->withCommands([
        __DIR__.'/../app/Console/Commands',
    ])
    ->withMiddleware(function (Middleware $middleware) use ($trustedProxyCidrs): void {
        $middleware->alias([
            'abilities' => CheckAbilities::class,
            'ability' => CheckForAnyAbility::class,
        ]);
        $middleware->appendToGroup('web', RequireConfirmedTwoFactorForPasskeys::class);

        $middleware->trustProxies(
            at: $trustedProxyCidrs,
            headers: Request::HEADER_X_FORWARDED_FOR
                | Request::HEADER_X_FORWARDED_PROTO,
        );
    })
    ->withExceptions(function (Exceptions $exceptions): void {
        $shouldRenderJson = static fn (Request $request): bool => $request->routeIs(
            'passport.token',
            'mobile.*',
            'pairing.*',
            'services.*',
        ) || $request->expectsJson();

        $exceptions->render(static function (AuthenticationException $exception, Request $request) use ($shouldRenderJson) {
            return $shouldRenderJson($request) ? response()->json(['message' => 'Unauthenticated.'], 401) : null;
        });
        $exceptions->render(static function (AuthorizationException $exception, Request $request) use ($shouldRenderJson) {
            return $shouldRenderJson($request) ? response()->json(['message' => 'Forbidden'], 403) : null;
        });
        $exceptions->render(static function (HttpExceptionInterface $exception, Request $request) use ($shouldRenderJson) {
            return $exception->getStatusCode() === 403 && $shouldRenderJson($request)
                ? response()->json(['message' => 'Forbidden'], 403)
                : null;
        });
        $exceptions->shouldRenderJsonWhen(
            $shouldRenderJson,
        );
    })->create();
