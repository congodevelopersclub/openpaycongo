<?php

declare(strict_types=1);

namespace App\Http\Controllers;

use App\Http\Requests\ConfirmPairingIntentRequest;
use App\Http\Responses\PairingProblem;
use App\Pairing\ConfirmPairingIntent;
use App\Pairing\PairingConfirmationConflict;
use App\Pairing\PairingConfirmationUnavailable;
use Illuminate\Http\JsonResponse;

final class ConfirmPairingIntentController
{
    public function __invoke(
        ConfirmPairingIntentRequest $request,
        ConfirmPairingIntent $confirmation,
        string $intent_id,
    ): JsonResponse {
        try {
            $status = $confirmation->confirm(
                $request->operator(),
                $intent_id,
                $request->requestId(),
                $request->decision(),
            );

            return response()->json(['status' => $status], 200, ['Cache-Control' => 'private, no-store']);
        } catch (PairingConfirmationConflict) {
            return PairingProblem::requestFailed(409);
        } catch (PairingConfirmationUnavailable) {
            return PairingProblem::unavailable();
        }
    }
}
