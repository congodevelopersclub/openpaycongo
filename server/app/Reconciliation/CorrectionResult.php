<?php

namespace App\Reconciliation;

final readonly class CorrectionResult
{
    public function __construct(public bool $repaired) {}
}
