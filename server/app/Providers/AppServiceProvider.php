<?php

namespace App\Providers;

use App\Http\Responses\PasskeyLoginResponse;
use App\Models\Deposit;
use App\OAuth\ClientScopeRepository;
use App\Operations\LaravelMigrationReadiness;
use App\Operations\LedgerProjectionReadiness;
use App\Operations\MigrationReadiness;
use App\Operations\ProjectionReadiness;
use App\Policies\DepositPolicy;
use App\Security\EstablishedFinancialOperatorMfaSession;
use App\Security\FinancialOperatorMfaSession;
use Illuminate\Cache\RateLimiting\Limit;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Gate;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Support\ServiceProvider;
use Laravel\Passkeys\Contracts\PasskeyLoginResponse as PasskeyLoginResponseContract;
use Laravel\Passport\Bridge\ScopeRepository as PassportScopeRepository;
use Laravel\Passport\Passport;

class AppServiceProvider extends ServiceProvider
{
    /**
     * Register any application services.
     */
    public function register(): void
    {
        Passport::ignoreRoutes();

        $this->app->bind(PassportScopeRepository::class, ClientScopeRepository::class);

        $this->app->bind(ProjectionReadiness::class, LedgerProjectionReadiness::class);
        $this->app->bind(MigrationReadiness::class, LaravelMigrationReadiness::class);
        $this->app->bind(FinancialOperatorMfaSession::class, EstablishedFinancialOperatorMfaSession::class);
        $this->app->singleton(PasskeyLoginResponseContract::class, PasskeyLoginResponse::class);
    }

    /**
     * Bootstrap any application services.
     */
    public function boot(): void
    {
        config()->set('passkeys', config('openpay.passkeys'));

        Passport::tokensCan([
            'payment-requests:read' => 'Read payment requests.',
            'payment-requests:write' => 'Create or update payment requests.',
            'deposits:read' => 'Read deposits.',
            'wallets:read' => 'Read customer credit balances.',
            'customers:read' => 'Read customer references.',
            'customers:pii:read' => 'Read customer PII when separately authorized.',
        ]);
        Passport::tokensExpireIn(now()->addMinutes(15));
        RateLimiter::for('mobile-api', static fn (Request $request): Limit => Limit::perMinute(60)->by((string) $request->user('mobile')?->getAuthIdentifier()));

        Gate::policy(Deposit::class, DepositPolicy::class);
    }
}
