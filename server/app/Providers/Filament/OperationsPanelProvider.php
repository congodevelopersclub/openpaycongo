<?php

namespace App\Providers\Filament;

use App\Filament\Pages\IssuePairingIntent;
use App\Filament\Pages\ReconcileDeposit;
use App\Http\Middleware\RequireFinancialOperatorMfa;
use Filament\Panel;
use Filament\PanelProvider;

final class OperationsPanelProvider extends PanelProvider
{
    public function panel(Panel $panel): Panel
    {
        return $panel
            ->id('operations')
            ->path('operations')
            ->pages([ReconcileDeposit::class, IssuePairingIntent::class])
            ->authMiddleware([RequireFinancialOperatorMfa::class]);
    }
}
