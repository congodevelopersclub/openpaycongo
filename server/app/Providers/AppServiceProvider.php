<?php

namespace App\Providers;

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
    }

    /**
     * Bootstrap any application services.
     */
    public function boot(): void
    {
        Gate::policy(Deposit::class, DepositPolicy::class);
    }
}
