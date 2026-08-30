<?php

use App\Http\Controllers\InitialSetupController;
use App\Http\Controllers\InitialSetupSecurityController;
use App\Http\Middleware\EnsureInitialSetupAvailable;
use Illuminate\Support\Facades\Route;

Route::get('/', function () {
    return view('welcome');
});

Route::middleware(EnsureInitialSetupAvailable::class)->group(function (): void {
    Route::get('/setup', InitialSetupController::class)->name('setup.initial');
    Route::post('/setup', [InitialSetupController::class, 'store'])->name('setup.initial.store');
});
Route::get('/setup/security', InitialSetupSecurityController::class)->middleware('auth')->name('setup.security');
Route::post('/setup/security/recovery-codes/acknowledge', [InitialSetupSecurityController::class, 'acknowledgeRecoveryCodes'])
    ->middleware('auth')
    ->name('setup.recovery-codes.acknowledge');
