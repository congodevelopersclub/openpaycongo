<?php

namespace App\Providers;

use App\Http\Responses\PasskeyLoginResponse;
use App\Models\Deposit;
use App\Operations\LaravelMigrationReadiness;
use App\Operations\LedgerProjectionReadiness;
use App\Operations\MigrationReadiness;
use App\Operations\ProjectionReadiness;
use App\Policies\DepositPolicy;
use App\Security\EstablishedFinancialOperatorMfaSession;
use App\Security\FinancialOperatorMfaSession;
use Illuminate\Support\Facades\Gate;
use Illuminate\Support\ServiceProvider;
use Laravel\Passkeys\Contracts\PasskeyLoginResponse as PasskeyLoginResponseContract;

class AppServiceProvider extends ServiceProvider
{
    /**
     * Register any application services.
     */
    public function register(): void
    {
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

        Gate::policy(Deposit::class, DepositPolicy::class);
    }
}
