<?php

namespace App\Reconciliation;

final readonly class ReconciliationReport
{
    /** @param list<string> $discrepancies */
    public function __construct(
        public bool $isReconciled,
        public array $discrepancies,
    ) {}
}
