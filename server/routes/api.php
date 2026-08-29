<?php

declare(strict_types=1);

use Illuminate\Support\Facades\Route;

Route::get('/healthz', static fn () => response()->json(['status' => 'ok']));

Route::get('/readyz', static fn () => response()->json([
    'datastore' => 'ok',
    'migration' => 'pending',
    'topology' => 'unsupported',
    'projection' => 'failed',
    'write_admission' => 'closed',
    'contract_version' => 'unimplemented',
    'migration_revision' => 'unimplemented',
    'adapter' => 'sqlite',
    'implementation' => 'congo-openpay-server',
], 503, ['cache-control' => 'no-store']));

Route::get('/version', static fn () => response()->json([
    'build' => 'dev',
    'contract_version' => 'unimplemented',
    'implementation' => 'congo-openpay-server',
    'adapter' => 'sqlite',
    'migration_revision' => 'unimplemented',
], 200, ['cache-control' => 'no-store']));
