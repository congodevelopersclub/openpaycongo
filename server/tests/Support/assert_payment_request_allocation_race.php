<?php

use App\Models\CustomerCredit;
use App\Models\CustomerCreditPosting;
use App\Models\PaymentRequest;
use App\PaymentRequests\PaymentRequestStatus;
use Illuminate\Contracts\Console\Kernel;

require __DIR__.'/../../vendor/autoload.php';

$app = require __DIR__.'/../../bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$expected = [
    '00000000-0000-4000-8000-000000000211' => [PaymentRequestStatus::Charged, 0],
    '00000000-0000-4000-8000-000000000212' => [PaymentRequestStatus::Pending, 100],
    '00000000-0000-4000-8000-000000000213' => [PaymentRequestStatus::Expired, 50],
    '00000000-0000-4000-8000-000000000214' => [PaymentRequestStatus::Pending, 50],
];

foreach ($expected as $id => [$status, $remaining]) {
    $request = PaymentRequest::query()->findOrFail($id);
    if ($request->status !== $status || (int) $request->remaining_minor !== $remaining) {
        throw new RuntimeException("Unexpected allocation state for {$id}.");
    }
}

$customerId = PaymentRequest::query()->findOrFail('00000000-0000-4000-8000-000000000211')->customer_id;
$credit = CustomerCredit::query()->where('customer_id', $customerId)->where('currency', 'CDF')->firstOrFail();
if ((int) $credit->available_minor !== 0
    || CustomerCredit::query()->where('customer_id', $customerId)->where('currency', 'USD')->exists()
    || CustomerCreditPosting::query()->where('customer_credit_id', $credit->id)->count() !== 2
    || (int) CustomerCreditPosting::query()->where('customer_credit_id', $credit->id)->sum('amount_minor') !== 100) {
    throw new RuntimeException('Concurrent allocation credit state is not exact.');
}
