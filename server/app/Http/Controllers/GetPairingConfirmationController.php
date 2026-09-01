<?php

declare(strict_types=1);

namespace App\Http\Controllers;

use App\Http\Responses\PairingProblem;
use App\Models\User;
use App\Pairing\ConfirmPairingIntent;
use App\Pairing\PairingConfirmationUnavailable;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

final class GetPairingConfirmationController
{
    public function __invoke(Request $request, ConfirmPairingIntent $confirmation, string $intent_id): JsonResponse
    {
        $operator = $request->user();
        if (! $operator instanceof User) {
            return PairingProblem::requestFailed(403);
        }

        try {
            return response()->json(
                $confirmation->display($operator, $intent_id),
                200,
                ['Cache-Control' => 'private, no-store'],
            );
        } catch (PairingConfirmationUnavailable) {
            return PairingProblem::unavailable();
        }
    }
}
