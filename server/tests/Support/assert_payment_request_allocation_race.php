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
    $request = PaymentRequest::query()->find($id);
    if ($request === null || $request->status !== $status || (int) $request->remaining_minor !== $remaining) {
        fwrite(STDERR, "Unexpected allocation state for {$id}.\n");
        exit(1);
    }
}

$first = PaymentRequest::query()->find('00000000-0000-4000-8000-000000000211');
$credit = $first === null ? null : CustomerCredit::query()->where('customer_id', $first->customer_id)->where('currency', 'CDF')->first();
if ($credit === null
    || (int) $credit->available_minor !== 50
    || CustomerCredit::query()->where('customer_id', $first->customer_id)->where('currency', 'USD')->exists()
    || CustomerCreditPosting::query()->where('customer_credit_id', $credit->id)->count() !== 2
    || (int) CustomerCreditPosting::query()->where('customer_credit_id', $credit->id)->sum('amount_minor') !== 150) {
    fwrite(STDERR, "Concurrent allocation credit state is not exact.\n");
    exit(1);
}
