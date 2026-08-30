<?php

use App\Events\CustomerCreditCreationPending;
use App\Models\Deposit;
use App\PaymentRequests\AllocatePendingPaymentRequests;
use Illuminate\Contracts\Console\Kernel;
use Illuminate\Support\Facades\Event;

require __DIR__.'/../../vendor/autoload.php';
$app = require __DIR__.'/../../bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$barrier = (string) getenv('PAYMENT_REQUEST_TEST_BARRIER_DIRECTORY');
$worker = (string) getenv('PAYMENT_REQUEST_TEST_WORKER');
touch($barrier.'/'.$worker.'.ready');
$deadline = microtime(true) + 30;
while (! file_exists($barrier.'/release')) {
    if (microtime(true) > $deadline) {
        throw new RuntimeException('Timed out waiting for payment request allocation barrier.');
    }

    usleep(10_000);
}

Event::listen(CustomerCreditCreationPending::class, function () use ($barrier, $worker): void {
    touch($barrier.'/'.$worker.'.transaction-ready');
    $deadline = microtime(true) + 30;
    while (! file_exists($barrier.'/transaction-release')) {
        if (microtime(true) > $deadline) {
            throw new RuntimeException('Timed out waiting for payment request allocation transaction barrier.');
        }
        usleep(10_000);
    }
});

app(AllocatePendingPaymentRequests::class)->forDeposit(Deposit::query()->findOrFail((string) getenv('PAYMENT_REQUEST_TEST_DEPOSIT_ID')));
echo "allocated\n";
