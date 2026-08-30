<?php

use App\Models\Customer;
use App\Models\CustomerCredit;
use App\Models\CustomerCreditPosting;
use App\Models\Deposit;
use App\Models\LedgerEntry;
use App\Models\SourceInstallation;
use Carbon\CarbonImmutable;
use Illuminate\Contracts\Console\Kernel;

require __DIR__.'/../../vendor/autoload.php';

$app = require __DIR__.'/../../bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$now = CarbonImmutable::now()->startOfSecond();
$customer = Customer::query()->forceCreate([
    'id' => '00000000-0000-4000-8000-000000000301',
    'organization_id' => '00000000-0000-4000-8000-000000000001',
    'private_lookup_digest' => str_repeat('d', 64),
    'private_lookup_id' => '00000000-0000-4000-8000-000000000302',
    'private_lookup_key_version' => 'v1',
]);
$installation = SourceInstallation::query()->forceCreate([
    'id' => '00000000-0000-4000-8000-000000000303',
    'organization_id' => $customer->organization_id,
    'installation_digest' => str_repeat('e', 64),
    'installation_lookup_id' => '00000000-0000-4000-8000-000000000304',
    'installation_key_version' => 'v1',
]);

$ids = [];
$credit = CustomerCredit::query()->forceCreate([
    'customer_id' => $customer->id,
    'currency' => 'CDF',
    'available_minor' => 200,
]);
foreach (['00000000-0000-4000-8000-000000000321', '00000000-0000-4000-8000-000000000322'] as $id) {
    $deposit = Deposit::query()->forceCreate([
        'id' => $id,
        'organization_id' => $customer->organization_id,
        'customer_id' => $customer->id,
        'source_installation_id' => $installation->id,
        'kind' => 'provider_credit',
        'amount_minor' => 100,
        'currency' => 'CDF',
        'received_at' => $now,
        'idempotency_digest' => hash('sha256', $id),
        'idempotency_key_version' => 'v1',
    ]);
    foreach ([
        ['provider_receivable', 100, 0],
        ['customer_credit', 0, 100],
    ] as [$account, $debit, $creditMinor]) {
        LedgerEntry::query()->create([
            'deposit_id' => $deposit->id,
            'organization_id' => $customer->organization_id,
            'account' => $account,
            'debit_minor' => $debit,
            'credit_minor' => $creditMinor,
            'currency' => 'CDF',
            'recorded_at' => $now,
        ]);
    }
    CustomerCreditPosting::query()->create([
        'deposit_id' => $deposit->id,
        'customer_credit_id' => $credit->id,
        'amount_minor' => 100,
    ]);
    $ids[] = $deposit->id;
}

echo implode(',', $ids);
