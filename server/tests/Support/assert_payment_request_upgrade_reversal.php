<?php

use Illuminate\Contracts\Console\Kernel;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

require __DIR__.'/../../vendor/autoload.php';

$app = require __DIR__.'/../../bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

Artisan::call('migrate:fresh', ['--force' => true]);
Artisan::call('migrate:rollback', ['--step' => 1]);

$organizationId = '00000000-0000-4000-8000-000000000166';
$customerId = (string) Str::uuid();
$installationId = (string) Str::uuid();
$depositId = (string) Str::uuid();
$reversalId = (string) Str::uuid();
$now = now();
DB::table('customers')->insert(['id' => $customerId, 'organization_id' => $organizationId, 'private_lookup_digest' => str_repeat('a', 64), 'created_at' => $now, 'updated_at' => $now]);
DB::table('source_installations')->insert(['id' => $installationId, 'organization_id' => $organizationId, 'installation_digest' => str_repeat('b', 64), 'created_at' => $now, 'updated_at' => $now]);
foreach ([[$depositId, null, 'provider_credit'], [$reversalId, $depositId, 'provider_reversal']] as [$id, $reversesDepositId, $kind]) {
    DB::table('deposits')->insert(['id' => $id, 'organization_id' => $organizationId, 'customer_id' => $customerId, 'source_installation_id' => $installationId, 'reverses_deposit_id' => $reversesDepositId, 'kind' => $kind, 'amount_minor' => 500, 'currency' => 'CDF', 'received_at' => $now, 'idempotency_digest' => hash('sha256', $id), 'created_at' => $now, 'updated_at' => $now]);
}
foreach ([[$depositId, 'provider_receivable', 500, 0], [$depositId, 'customer_credit', 0, 500], [$reversalId, 'customer_credit', 500, 0], [$reversalId, 'provider_receivable', 0, 500]] as [$deposit, $account, $debit, $credit]) {
    DB::table('ledger_entries')->insert(['id' => (string) Str::uuid(), 'deposit_id' => $deposit, 'organization_id' => $organizationId, 'account' => $account, 'debit_minor' => $debit, 'credit_minor' => $credit, 'currency' => 'CDF', 'recorded_at' => $now, 'created_at' => $now, 'updated_at' => $now]);
}

Artisan::call('migrate', ['--force' => true]);
Artisan::call('payment-requests:recover-credit');

$balance = DB::table('customer_credits')->where('customer_id', $customerId)->where('currency', 'CDF')->value('available_minor');
$postings = DB::table('customer_credit_postings')->where('deposit_id', $depositId)->count();
if ((int) $balance !== 0 || $postings !== 1) {
    throw new RuntimeException('Historical reversal upgrade changed customer credit.');
}
