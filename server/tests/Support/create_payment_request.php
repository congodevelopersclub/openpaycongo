<?php

use App\PaymentRequests\CreatePaymentRequest;
use Illuminate\Contracts\Console\Kernel;

require __DIR__.'/../../vendor/autoload.php';

$app = require __DIR__.'/../../bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$barrierDirectory = getenv('PAYMENT_REQUEST_TEST_BARRIER_DIRECTORY');
if (is_string($barrierDirectory) && $barrierDirectory !== '') {
    $worker = getenv('PAYMENT_REQUEST_TEST_WORKER');
    if (! is_string($worker) || $worker === '') {
        throw new RuntimeException('Payment request test worker is required.');
    }

    touch($barrierDirectory.'/'.$worker.'.ready');
    $deadline = microtime(true) + 30;
    while (! file_exists($barrierDirectory.'/release')) {
        if (microtime(true) > $deadline) {
            throw new RuntimeException('Timed out waiting for payment request barrier.');
        }
        usleep(10_000);
    }
}

$request = app(CreatePaymentRequest::class)->create(
    (string) getenv('PAYMENT_REQUEST_TEST_CUSTOMER_ID'),
    (int) (getenv('PAYMENT_REQUEST_TEST_AMOUNT_MINOR') ?: 100),
    (string) (getenv('PAYMENT_REQUEST_TEST_CURRENCY') ?: 'CDF'),
);

echo $request->status->value;
