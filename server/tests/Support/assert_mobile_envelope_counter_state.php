<?php

use App\Models\Deposit;
use App\Models\LedgerEntry;
use App\Models\SourceInstallation;
use Illuminate\Contracts\Console\Kernel;

require dirname(__DIR__, 2).'/vendor/autoload.php';

$app = require dirname(__DIR__, 2).'/bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$organizationId = '00000000-0000-4000-8000-000000000211';
$installation = SourceInstallation::query()->find('00000000-0000-4000-8000-000000000210');
$deposits = Deposit::query()->where('organization_id', $organizationId)->get();

if (! $installation instanceof SourceInstallation
    || (int) $installation->mobile_replay_counter !== 1
    || $deposits->count() !== 1
    || LedgerEntry::query()->whereIn('deposit_id', $deposits->pluck('id'))->count() !== 2) {
    throw new RuntimeException('Mobile envelope counter concurrency state is not exact.');
}
