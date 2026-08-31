<?php

use App\Pairing\ReservePairingCompletion;
use Illuminate\Contracts\Console\Kernel;

require dirname(__DIR__, 2).'/vendor/autoload.php';

$app = require dirname(__DIR__, 2).'/bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$barrierDirectory = getenv('PAIRING_TEST_BARRIER_DIRECTORY');
$worker = getenv('PAIRING_TEST_WORKER');
if (! is_string($barrierDirectory) || $barrierDirectory === '' || ! is_string($worker) || $worker === '') {
    throw new RuntimeException('Pairing concurrency barrier unavailable.');
}

touch($barrierDirectory.'/'.$worker.'.ready');
$deadline = microtime(true) + 30;
while (! file_exists($barrierDirectory.'/release')) {
    if (microtime(true) >= $deadline) {
        throw new RuntimeException('Pairing concurrency barrier timed out.');
    }
    usleep(10_000);
}

$intentBytes = hex2bin('00112233445566778899aabbccddeeff');
if ($intentBytes === false) {
    throw new RuntimeException('Pairing concurrency fixture unavailable.');
}

echo $app->make(ReservePairingCompletion::class)
    ->reserve($intentBytes, hash('sha256', 'pairing-concurrency-request', true))
    ->outcome()
    ->value;
