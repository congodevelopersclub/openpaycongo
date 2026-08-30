<?php

use App\Http\Controllers\InitialSetupController;
use Illuminate\Support\Facades\Route;

Route::get('/', function () {
    return view('welcome');
});

Route::get('/setup', InitialSetupController::class)->name('setup.initial');
Route::post('/setup', [InitialSetupController::class, 'store'])->name('setup.initial.store');
