<?php

use App\Models\CustomerCredit;
use App\Models\CustomerCreditPosting;
use App\Models\Deposit;
use App\Models\LedgerEntry;
use Illuminate\Contracts\Console\Kernel;

require __DIR__.'/../../vendor/autoload.php';

$app = require __DIR__.'/../../bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$customerId = '00000000-0000-4000-8000-000000000301';
$credit = CustomerCredit::query()->where('customer_id', $customerId)->where('currency', 'CDF')->firstOrFail();
if ((int) $credit->available_minor !== -200
    || CustomerCredit::query()->where('customer_id', $customerId)->count() !== 1
    || Deposit::query()->where('customer_id', $customerId)->where('kind', 'provider_reversal')->count() !== 2
    || CustomerCreditPosting::query()->where('customer_credit_id', $credit->id)->where('amount_minor', -100)->count() !== 2
    || LedgerEntry::query()->whereIn('deposit_id', Deposit::query()->where('customer_id', $customerId)->where('kind', 'provider_reversal')->select('id'))->count() !== 4) {
    throw new RuntimeException('Concurrent reversal credit state is not exact.');
}
