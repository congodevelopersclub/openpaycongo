<?php

use App\Models\PairingCompletionReservation;
use App\Models\PairingIntent;
use Illuminate\Contracts\Console\Kernel;

require dirname(__DIR__, 2).'/vendor/autoload.php';

$app = require dirname(__DIR__, 2).'/bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$intent = PairingIntent::query()->firstOrFail();
if ($intent->state !== 'pending' || (int) $intent->invalid_proof_attempts !== 0
    || PairingCompletionReservation::query()->where('state', 'reserved')->count() !== 1) {
    throw new RuntimeException('Pairing completion concurrency state is not exact.');
}
