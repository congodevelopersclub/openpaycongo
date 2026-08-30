<?php

use App\Models\Customer;
use App\Models\Deposit;
use App\Models\PaymentRequest;
use App\Models\SourceInstallation;
use App\PaymentRequests\PaymentRequestStatus;
use Carbon\CarbonImmutable;
use Illuminate\Contracts\Console\Kernel;

require __DIR__.'/../../vendor/autoload.php';
$app = require __DIR__.'/../../bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();
$now = CarbonImmutable::now()->startOfSecond();
$customer = Customer::query()->create([
    'organization_id' => '00000000-0000-4000-8000-000000000001', 'private_lookup_digest' => str_repeat('b', 64),
    'private_lookup_id' => '00000000-0000-4000-8000-000000000201', 'private_lookup_key_version' => 'v1',
]);
$installation = SourceInstallation::query()->create([
    'organization_id' => $customer->organization_id, 'installation_digest' => str_repeat('c', 64),
    'installation_lookup_id' => '00000000-0000-4000-8000-000000000202', 'installation_key_version' => 'v1',
]);
foreach ([
    ['00000000-0000-4000-8000-000000000211', 'CDF', 100, $now->addDay()],
    ['00000000-0000-4000-8000-000000000212', 'CDF', 100, $now->addDay()],
    ['00000000-0000-4000-8000-000000000213', 'CDF', 50, $now->subSecond()],
    ['00000000-0000-4000-8000-000000000214', 'USD', 50, $now->addDay()],
] as [$id, $currency, $amount, $expires]) {
    PaymentRequest::query()->forceCreate([
        'id' => $id,
        'customer_id' => $customer->id,
        'idempotency_digest' => hash('sha256', $id),
        'idempotency_key_fingerprint' => hash_hmac('sha256', 'openpay.payment-request.idempotency-key-fingerprint.v1', 'testing-deposit-lookup-key-material-32'),
        'currency' => $currency,
        'amount_minor' => $amount,
        'remaining_minor' => $amount,
        'status' => PaymentRequestStatus::Pending,
        'expires_at' => $expires,
        'created_at' => $now,
        'updated_at' => $now,
    ]);
}

$ids = [];
foreach ([
    ['00000000-0000-4000-8000-000000000221', 75],
    ['00000000-0000-4000-8000-000000000222', 75],
] as [$id, $amount]) {
    $ids[] = Deposit::query()->forceCreate([
        'id' => $id,
        'organization_id' => $customer->organization_id,
        'customer_id' => $customer->id,
        'source_installation_id' => $installation->id,
        'kind' => 'provider_credit',
        'amount_minor' => $amount,
        'currency' => 'CDF',
        'received_at' => $now,
        'idempotency_digest' => hash('sha256', $id),
        'idempotency_key_version' => 'v1',
    ])->id;
}
echo implode(',', $ids);
