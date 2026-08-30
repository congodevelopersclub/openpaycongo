<?php

use App\Models\Customer;
use App\Models\PaymentRequest;
use App\Models\PaymentRequestAllocationDelivery;
use App\PaymentRequests\PaymentRequestStatus;
use Carbon\CarbonImmutable;
use Illuminate\Contracts\Console\Kernel;

require __DIR__.'/../../vendor/autoload.php';

$app = require __DIR__.'/../../bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$customer = Customer::query()->create([
    'organization_id' => '00000000-0000-4000-8000-000000000001',
    'private_lookup_digest' => str_repeat('f', 64),
    'private_lookup_id' => '00000000-0000-4000-8000-000000000401',
    'private_lookup_key_version' => 'v1',
]);
$request = PaymentRequest::query()->forceCreate([
    'id' => '00000000-0000-4000-8000-000000000411',
    'customer_id' => $customer->id,
    'idempotency_digest' => hash('sha256', 'callback-race'),
    'idempotency_key_fingerprint' => hash_hmac('sha256', 'openpay.payment-request.idempotency-key-fingerprint.v1', 'testing-deposit-lookup-key-material-32'),
    'currency' => 'CDF',
    'amount_minor' => 100,
    'remaining_minor' => 0,
    'status' => PaymentRequestStatus::Charged,
    'expires_at' => CarbonImmutable::now()->addDay(),
    'charged_at' => CarbonImmutable::now(),
]);
$delivery = PaymentRequestAllocationDelivery::query()->create(['payment_request_id' => $request->id]);

echo $delivery->id;
