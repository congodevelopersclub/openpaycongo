<?php

declare(strict_types=1);

use App\Http\Controllers\CompletePairingEnvelopeController;
use App\Http\Controllers\ConfirmPairingIntentController;
use App\Http\Controllers\GetPairingActivationController;
use App\Http\Controllers\GetPairingConfirmationController;
use App\Http\Controllers\IssuePairingIntentController;
use App\Http\Controllers\StoreMobileDepositController;
use App\Http\Middleware\RequireClientCredentialsGrant;
use App\Http\Middleware\ResolveDeveloperApplication;
use App\Models\DeveloperApplication;
use App\Operations\AssessReadiness;
use App\Operations\MigrationReadiness;
use Illuminate\Support\Facades\Route;
use Laravel\Passport\Http\Controllers\AccessTokenController;
use Laravel\Passport\Http\Middleware\CheckToken;

Route::get('/healthz', static fn () => response()->json(['status' => 'ok']));

Route::post('/oauth/token', [AccessTokenController::class, 'issueToken'])
    ->middleware([RequireClientCredentialsGrant::class, 'throttle'])
    ->name('passport.token');

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
})->middleware(['auth:mobile', 'abilities:mobile:sync:read', 'throttle:mobile-api'])
    ->name('mobile.identity');

Route::post('/mobile/deposits', StoreMobileDepositController::class)
    ->middleware(['auth:mobile', 'abilities:mobile:deposits:write', 'throttle:mobile-api'])
    ->name('mobile.deposits.store');

Route::post('/v1/pairing/intents', IssuePairingIntentController::class)
    ->middleware(['web', 'auth', 'pairing.issuer'])
    ->name('pairing.intents.store');

Route::get('/v1/pairing/intents/{intent_id}/confirmation', GetPairingConfirmationController::class)
    ->middleware(['web', 'auth', 'pairing.issuer'])
    ->name('pairing.intents.confirmation.show');

Route::post('/v1/pairing/intents/{intent_id}/confirmation', ConfirmPairingIntentController::class)
    ->middleware(['web', 'auth', 'pairing.issuer'])
    ->name('pairing.intents.confirmation.store');

Route::get('/v1/pairing/intents/{intent_id}/activation', GetPairingActivationController::class)
    ->name('pairing.intents.activation.show');

Route::post('/v1/pairing/complete', CompletePairingEnvelopeController::class)
    ->name('pairing.complete');

Route::get('/services/identity', static function () {
    /** @var DeveloperApplication $application */
    $application = request()->attributes->get(DeveloperApplication::class);

    return response()->json([
        'application_id' => $application->getKey(),
        'organization_id' => $application->organization_id,
    ], 200, ['cache-control' => 'no-store']);
})->middleware([CheckToken::using('payment-requests:read'), ResolveDeveloperApplication::class])
    ->name('services.identity');
