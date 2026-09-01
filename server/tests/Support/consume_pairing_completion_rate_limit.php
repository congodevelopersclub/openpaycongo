<?php

use App\Pairing\PairingRateLimitAdmission;
use App\Pairing\PairingRateLimitAdmissionUnavailable;
use Illuminate\Contracts\Console\Kernel;

require dirname(__DIR__, 2).'/vendor/autoload.php';

$app = require dirname(__DIR__, 2).'/bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$barrierDirectory = getenv('PAIRING_TEST_BARRIER_DIRECTORY');
$worker = getenv('PAIRING_TEST_WORKER');
if (! is_string($barrierDirectory) || $barrierDirectory === '' || ! is_string($worker) || $worker === '') {
    throw new RuntimeException('Pairing rate-limit concurrency barrier unavailable.');
}

touch($barrierDirectory.'/'.$worker.'.ready');
$deadline = microtime(true) + 30;
while (! file_exists($barrierDirectory.'/release')) {
    if (microtime(true) >= $deadline) {
        throw new RuntimeException('Pairing rate-limit concurrency barrier timed out.');
    }
    usleep(10_000);
}

try {
    $retryAfter = $app->make(PairingRateLimitAdmission::class)
        ->consume('pairing-completion-concurrency', 10, 60);

    echo $retryAfter === null ? 'admitted' : 'rate_limited';
} catch (PairingRateLimitAdmissionUnavailable) {
    echo 'retryable';
}
