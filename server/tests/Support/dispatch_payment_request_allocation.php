<?php

use App\Events\PaymentRequestAllocated;
use App\Jobs\DispatchPaymentRequestAllocation;
use Illuminate\Contracts\Console\Kernel;
use Illuminate\Support\Facades\Event;

require __DIR__.'/../../vendor/autoload.php';

$app = require __DIR__.'/../../bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$barrier = (string) getenv('PAYMENT_REQUEST_TEST_BARRIER_DIRECTORY');
$worker = (string) getenv('PAYMENT_REQUEST_TEST_WORKER');
Event::listen(PaymentRequestAllocated::class, function (PaymentRequestAllocated $event) use ($barrier, $worker): void {
    file_put_contents($barrier.'/callback-'.$worker, $event->paymentRequestId, LOCK_EX);
    usleep(2_000_000);
});

touch($barrier.'/'.$worker.'.ready');
$deadline = microtime(true) + 30;
while (! file_exists($barrier.'/release')) {
    if (microtime(true) > $deadline) {
        throw new RuntimeException('Timed out waiting for payment request callback barrier.');
    }

    usleep(10_000);
}

app(DispatchPaymentRequestAllocation::class, ['deliveryId' => (string) getenv('PAYMENT_REQUEST_TEST_DELIVERY_ID')])->handle();
echo "handled\n";
