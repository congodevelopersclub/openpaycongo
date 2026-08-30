<?php

use App\Models\PaymentRequestAllocationDelivery;
use Illuminate\Contracts\Console\Kernel;

require __DIR__.'/../../vendor/autoload.php';

$app = require __DIR__.'/../../bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$delivery = PaymentRequestAllocationDelivery::query()->find((string) getenv('PAYMENT_REQUEST_TEST_DELIVERY_ID'));
$callbacks = glob((string) getenv('PAYMENT_REQUEST_TEST_BARRIER_DIRECTORY').'/callback-*');
if ($delivery === null
    || $delivery->dispatched_at === null
    || $delivery->claimed_at !== null
    || $delivery->claim_token !== null
    || $callbacks === false
    || count($callbacks) !== 1
    || file_get_contents($callbacks[0]) !== $delivery->payment_request_id) {
    fwrite(STDERR, "Concurrent allocation callback claim state is not exact.\n");
    exit(1);
}
