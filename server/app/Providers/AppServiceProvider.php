<?php

namespace App\Providers;

use App\Http\Responses\PasskeyLoginResponse;
use App\Models\Deposit;
use App\Models\OAuthClient;
use App\OAuth\ClientScopeRepository;
use App\Operations\LaravelMigrationReadiness;
use App\Operations\LedgerProjectionReadiness;
use App\Operations\MigrationReadiness;
use App\Operations\ProjectionReadiness;
use App\Pairing\KeyProtector;
use App\Pairing\LaravelKeyProtector;
use App\Pairing\PairingRandom;
use App\Pairing\SecurePairingRandom;
use App\Policies\DepositPolicy;
use App\Security\EstablishedFinancialOperatorMfaSession;
use App\Security\FinancialOperatorMfaSession;
use Illuminate\Cache\RateLimiting\Limit;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Gate;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Support\ServiceProvider;
use Laravel\Passkeys\Contracts\PasskeyLoginResponse as PasskeyLoginResponseContract;
use Laravel\Passport\Bridge\ScopeRepository as PassportScopeRepository;
use Laravel\Passport\Passport;
use LogicException;

class AppServiceProvider extends ServiceProvider
{
    /**
     * Register any application services.
     */
    public function register(): void
    {
        Passport::ignoreRoutes();
        Passport::useClientModel(OAuthClient::class);

        $this->app->bind(PassportScopeRepository::class, ClientScopeRepository::class);

        $this->app->bind(ProjectionReadiness::class, LedgerProjectionReadiness::class);
        $this->app->bind(MigrationReadiness::class, LaravelMigrationReadiness::class);
        $this->app->bind(FinancialOperatorMfaSession::class, EstablishedFinancialOperatorMfaSession::class);
        $this->app->singleton(KeyProtector::class, LaravelKeyProtector::class);
        $this->app->singleton(PairingRandom::class, SecurePairingRandom::class);
        $this->app->singleton(PasskeyLoginResponseContract::class, PasskeyLoginResponse::class);
    }

    /**
     * Bootstrap any application services.
     */
    public function boot(): void
    {
        $passportKeysPath = config('openpay.passport_keys_path');
        if (is_string($passportKeysPath) === false || trim($passportKeysPath) === '') {
            throw new LogicException('Passport signing-key directory must be configured.');
        }

        Passport::loadKeysFrom($passportKeysPath);

        config()->set('passkeys', config('openpay.passkeys'));

        /** @var array<string, string> $serviceScopes */
        $serviceScopes = config('openpay.service_scopes');
        Passport::tokensCan($serviceScopes);
        Passport::tokensExpireIn(now()->addMinutes(15));
        RateLimiter::for('mobile-api', static fn (Request $request): Limit => Limit::perMinute(60)->by((string) $request->user('mobile')?->getAuthIdentifier()));
        RateLimiter::for('mobile-envelope', static function (Request $request): Limit {
            return Limit::perMinute(60)
                ->by('mobile-envelope:'.$request->ip())
                ->response(static function (Request $request, array $headers): JsonResponse {
                    return response()->json(['code' => 'mobile_envelope_unavailable'], 404, ['Cache-Control' => 'no-store, private']);
                });
        });
        Gate::policy(Deposit::class, DepositPolicy::class);
    }
}
