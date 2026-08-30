<?php

use App\Deposits\RecordProviderDeposit;
use App\Models\Deposit;
use Illuminate\Contracts\Console\Kernel;

require __DIR__.'/../../vendor/autoload.php';

$app = require __DIR__.'/../../bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$barrier = (string) getenv('PAYMENT_REQUEST_TEST_BARRIER_DIRECTORY');
$worker = (string) getenv('PAYMENT_REQUEST_TEST_WORKER');
touch($barrier.'/'.$worker.'.ready');
$deadline = microtime(true) + 30;
while (! file_exists($barrier.'/release')) {
    if (microtime(true) > $deadline) {
        throw new RuntimeException('Timed out waiting for payment request reversal barrier.');
    }

    usleep(10_000);
}

$result = app(RecordProviderDeposit::class)->reverse(
    Deposit::query()->findOrFail((string) getenv('PAYMENT_REQUEST_TEST_DEPOSIT_ID')),
);
echo $result->outcome->value.PHP_EOL;
