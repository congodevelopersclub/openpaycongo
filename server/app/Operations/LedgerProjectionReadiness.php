<?php

declare(strict_types=1);

namespace App\Operations;

use Illuminate\Support\Facades\Schema;

final class LedgerProjectionReadiness implements ProjectionReadiness
{
    public function status(): string
    {
        return Schema::hasTable('ledger_entries') ? 'healthy' : 'failed';
    }
}
