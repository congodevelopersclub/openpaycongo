<?php

declare(strict_types=1);

namespace App\Http\Controllers;

use App\Http\Responses\PairingProblem;
use App\Pairing\CompletePairingEnvelope;
use App\Pairing\PairingRateLimitAdmission;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Throwable;

final class CompletePairingEnvelopeController
{
    public function __invoke(
        Request $request,
        CompletePairingEnvelope $complete,
        PairingRateLimitAdmission $admission,
    ): JsonResponse {
        $limitKey = 'pairing.complete:'.hash('sha256', (string) $request->ip());

        try {
            $retryAfter = $admission->consume($limitKey, 10, 60);
            if ($retryAfter !== null) {
                return PairingProblem::rateLimited((string) $retryAfter);
            }

            return $this->complete($request, $complete);
        } catch (Throwable) {
            return PairingProblem::requestFailed(503);
        }
    }

    private function complete(Request $request, CompletePairingEnvelope $complete): JsonResponse
    {
        $input = $request->all();
        $expectedKeys = ['intent_id', 'client_public_key', 'nonce', 'ciphertext'];
        if (count($input) !== count($expectedKeys) || array_diff(array_keys($input), $expectedKeys) !== []) {
            return PairingProblem::unavailable();
        }
        $intentIdBytes = $this->decodeCanonicalBase64Url($input['intent_id']);
        $client = $this->decodeCanonicalBase64Url($input['client_public_key']);
        $nonce = $this->decodeCanonicalBase64Url($input['nonce']);
        $ciphertext = $this->decodeCanonicalBase64Url($input['ciphertext']);

        $result = is_string($intentIdBytes) && strlen($intentIdBytes) === 16 && is_string($client) && is_string($nonce) && is_string($ciphertext)
            ? $complete->execute($intentIdBytes, $client, $nonce, $ciphertext, hash('sha256', implode('', [$intentIdBytes, $client, $nonce, $ciphertext]), true))
            : null;

        if ($result === null) {
            return PairingProblem::unavailable();
        }

        return response()->json([
            'state' => $result['state'],
            'nonce' => rtrim(strtr(base64_encode($result['nonce']), '+/', '-_'), '='),
            'ciphertext' => rtrim(strtr(base64_encode($result['ciphertext']), '+/', '-_'), '='),
        ], 201, ['Cache-Control' => 'private, no-store']);
    }

    private function decodeCanonicalBase64Url(mixed $value): string|false
    {
        if (! is_string($value) || preg_match('/^[A-Za-z0-9_-]+$/D', $value) !== 1) {
            return false;
        }

        $decoded = base64_decode(strtr($value, '-_', '+/').str_repeat('=', (4 - strlen($value) % 4) % 4), true);

        return is_string($decoded) && rtrim(strtr(base64_encode($decoded), '+/', '-_'), '=') === $value
            ? $decoded
            : false;
    }
}
