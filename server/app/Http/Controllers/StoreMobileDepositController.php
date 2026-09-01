<?php

namespace App\Http\Controllers;

use App\Deposits\RecordResult;
use App\Deposits\SubmitMobileDeposit;
use App\Http\Requests\StoreMobileDepositRequest;
use App\Models\SourceInstallation;
use Illuminate\Http\JsonResponse;

final class StoreMobileDepositController
{
    public function __invoke(StoreMobileDepositRequest $request, SubmitMobileDeposit $deposits): JsonResponse
    {
        /** @var SourceInstallation $installation */
        $installation = $request->user('mobile');
        $result = $deposits->submit($installation, $request->validated());

        return response()->json(['outcome' => $result->outcome->value], match ($result->outcome) {
            RecordResult::Recorded => 201,
            RecordResult::Replayed => 200,
            RecordResult::Conflict => 409,
        }, ['cache-control' => 'no-store']);
    }
}
