<?php

use App\Models\Customer;
use App\Models\Deposit;
use App\Models\LedgerEntry;
use App\Models\SourceInstallation;
use Illuminate\Contracts\Console\Kernel;

require dirname(__DIR__, 2).'/vendor/autoload.php';

$app = require dirname(__DIR__, 2).'/bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$organizationId = '00000000-0000-4000-8000-000000000165';
$deposits = Deposit::query()->where('organization_id', $organizationId)->get();
$expectedDeposits = (int) (getenv('DEPOSIT_TEST_EXPECTED_DEPOSITS') ?: 1);
$expectedLedgerEntries = (int) (getenv('DEPOSIT_TEST_EXPECTED_LEDGER_ENTRIES') ?: 2);
$expectedCredit = (int) (getenv('DEPOSIT_TEST_EXPECTED_CREDIT_MINOR') ?: 12500);

if ($deposits->count() !== $expectedDeposits
    || Customer::query()->where('organization_id', $organizationId)->count() !== 1
    || SourceInstallation::query()->where('organization_id', $organizationId)->count() !== 1
    || LedgerEntry::query()->whereIn('deposit_id', $deposits->pluck('id'))->count() !== $expectedLedgerEntries
    || (int) LedgerEntry::query()->whereIn('deposit_id', $deposits->pluck('id'))->sum('credit_minor') !== $expectedCredit) {
    throw new RuntimeException('Provider deposit concurrency state is not exact.');
}
