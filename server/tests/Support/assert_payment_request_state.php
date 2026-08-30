<?php

use App\Models\CustomerCredit;
use App\Models\PaymentRequest;
use App\PaymentRequests\PaymentRequestStatus;
use Illuminate\Contracts\Console\Kernel;

require __DIR__.'/../../vendor/autoload.php';

$app = require __DIR__.'/../../bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$customerId = (string) getenv('PAYMENT_REQUEST_TEST_CUSTOMER_ID');
$charged = PaymentRequest::query()->where('customer_id', $customerId)->where('status', PaymentRequestStatus::Charged)->count();
$pending = PaymentRequest::query()->where('customer_id', $customerId)->where('status', PaymentRequestStatus::Pending)->count();
$available = CustomerCredit::query()->where('customer_id', $customerId)->where('currency', 'CDF')->value('available_minor');

if ($charged !== (int) getenv('PAYMENT_REQUEST_TEST_EXPECTED_CHARGED')
    || $pending !== (int) getenv('PAYMENT_REQUEST_TEST_EXPECTED_PENDING')
    || $available !== (int) getenv('PAYMENT_REQUEST_TEST_EXPECTED_AVAILABLE')) {
    fwrite(STDERR, "Payment request credit state is not exact.\n");
    exit(1);
}
