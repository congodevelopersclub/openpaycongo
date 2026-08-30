<?php

declare(strict_types=1);

use App\Http\Requests\ShowReconciliationReportRequest;
use App\Http\Resources\ReconciliationReportResource;
use App\Models\Deposit;
use App\Operations\AssessReadiness;
use App\Operations\MigrationReadiness;
use App\Reconciliation\ReconcileDeposit;
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

Route::get('/reconciliation/deposits/{deposit}', static function (ShowReconciliationReportRequest $request, Deposit $deposit, ReconcileDeposit $reconciliation): ReconciliationReportResource {
    return new ReconciliationReportResource($reconciliation->report($deposit));
})->middleware(['auth', 'can:view,deposit']);
