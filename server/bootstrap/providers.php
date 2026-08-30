<?php

use App\Providers\AppServiceProvider;
use App\Providers\Filament\OperationsPanelProvider;
use App\Providers\FortifyServiceProvider;

return [
    AppServiceProvider::class,
    FortifyServiceProvider::class,
    OperationsPanelProvider::class,
];
