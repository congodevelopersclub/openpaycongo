<?php

declare(strict_types=1);

namespace App\Http\Controllers;

use App\Http\Responses\PairingProblem;
use App\Pairing\PairingRateLimitAdmission;
use App\Pairing\RetrievePairingActivation;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Throwable;

final class GetPairingActivationController
{
    public function __invoke(
        Request $request,
        string $intent_id,
        RetrievePairingActivation $activation,
        PairingRateLimitAdmission $admission,
    ): JsonResponse {
        try {
            $retryAfter = $admission->consume('pairing.activation:'.hash('sha256', (string) $request->ip()), 10, 60);
            if ($retryAfter !== null) {
                return PairingProblem::rateLimited((string) $retryAfter);
            }
            $result = $activation->execute($intent_id);
        } catch (Throwable) {
            return PairingProblem::requestFailed(503);
        }

        if ($result === null) {
            return PairingProblem::unavailable();
        }

        return response()->json([
            'version' => 2,
            'nonce' => rtrim(strtr(base64_encode($result['nonce']), '+/', '-_'), '='),
            'ciphertext' => rtrim(strtr(base64_encode($result['ciphertext']), '+/', '-_'), '='),
        ], 200, ['Cache-Control' => 'private, no-store']);
    }
}
