<?php

declare(strict_types=1);

use App\Operations\AssessReadiness;
use Illuminate\Support\Facades\Route;

Route::get('/healthz', static fn () => response()->json(['status' => 'ok']));

Route::get('/readyz', static function (AssessReadiness $readiness) {
    $status = $readiness->assess();

    return response()->json($status['body'], $status['status'], ['cache-control' => 'no-store']);
});

Route::get('/version', static fn () => response()->json([
    'build' => 'dev',
    'contract_version' => 'unimplemented',
    'implementation' => 'congo-openpay-server',
    'adapter' => 'sqlite',
    'migration_revision' => 'unimplemented',
], 200, ['cache-control' => 'no-store']));
