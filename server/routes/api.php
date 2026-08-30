<?php

declare(strict_types=1);

use App\Operations\AssessReadiness;
use App\Operations\MigrationReadiness;
use Illuminate\Support\Facades\Route;

Route::get('/healthz', static fn () => response()->json(['status' => 'ok']));

Route::get('/readyz', static function (AssessReadiness $readiness) {
    $status = $readiness->assess();

    return response()->json($status['body'], $status['status'], ['cache-control' => 'no-store']);
});

Route::get('/version', static fn (MigrationReadiness $migrations) => response()->json([
    'build' => 'dev',
    'contract_version' => 'unimplemented',
    'implementation' => 'congo-openpay-server',
    'adapter' => config('database.default'),
    'migration_revision' => $migrations->revision(),
], 200, ['cache-control' => 'no-store']));

Route::get('/mobile/identity', static function () {
    $installation = request()->user('mobile');

    return response()->json(['organization_id' => $installation->organization_id], 200, ['cache-control' => 'no-store']);
})->middleware(['auth:mobile', 'abilities:mobile:sync:read', 'throttle:mobile-api']);
