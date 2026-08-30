<?php

namespace App\Http\Resources;

use App\Reconciliation\ReconciliationReport;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

/** @mixin ReconciliationReport */
final class ReconciliationReportResource extends JsonResource
{
    public function toArray(Request $request): array
    {
        return [
            'is_reconciled' => $this->resource->isReconciled,
            'discrepancies' => $this->resource->discrepancies,
        ];
    }
}
