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

if ($deposits->count() !== 1
    || Customer::query()->where('organization_id', $organizationId)->count() !== 1
    || SourceInstallation::query()->where('organization_id', $organizationId)->count() !== 1
    || LedgerEntry::query()->where('deposit_id', $deposits->sole()->id)->count() !== 2
    || (int) LedgerEntry::query()->where('deposit_id', $deposits->sole()->id)->sum('credit_minor') !== 12500) {
    throw new RuntimeException('Provider deposit concurrency state is not exact.');
}
