<?php

use App\Providers\AppServiceProvider;
use App\Providers\FortifyServiceProvider;
use App\Providers\Filament\OperationsPanelProvider;

return [
    AppServiceProvider::class,
    FortifyServiceProvider::class,
    OperationsPanelProvider::class,
];
