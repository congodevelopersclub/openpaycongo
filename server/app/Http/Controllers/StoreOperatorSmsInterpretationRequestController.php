<?php

declare(strict_types=1);

namespace App\Http\Controllers;

use App\Http\Requests\StoreOperatorSmsInterpretationRequest;
use App\Models\SourceInstallation;
use App\OperatorSms\RecordOperatorSmsInterpretationRequest;
use Illuminate\Http\JsonResponse;

final class StoreOperatorSmsInterpretationRequestController
{
    public function __invoke(
        StoreOperatorSmsInterpretationRequest $request,
        RecordOperatorSmsInterpretationRequest $requests,
    ): JsonResponse {
        /** @var SourceInstallation $installation */
        $installation = $request->user('mobile');
        $result = $requests->record($installation, $request->validated());

        return response()->json([
            'outcome' => $result->recorded ? 'accepted_for_pattern_review' : 'replayed',
            'request_id' => $result->request->id,
        ], $result->recorded ? 202 : 200, ['cache-control' => 'no-store']);
    }
}
