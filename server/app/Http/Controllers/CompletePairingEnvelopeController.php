<?php

declare(strict_types=1);

namespace App\Http\Controllers;

use App\Http\Responses\PairingProblem;
use App\Pairing\CompletePairingEnvelope;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\RateLimiter;

final class CompletePairingEnvelopeController
{
    public function __invoke(Request $request, CompletePairingEnvelope $complete): JsonResponse
    {
        $limitKey = 'pairing.complete:'.hash('sha256', (string) $request->ip());
        if (RateLimiter::tooManyAttempts($limitKey, 10)) {
            return PairingProblem::rateLimited((string) RateLimiter::availableIn($limitKey));
        }
        RateLimiter::hit($limitKey, 60);
        $input = $request->all();
        $expectedKeys = ['intent_id', 'client_public_key', 'nonce', 'ciphertext'];
        if (count($input) !== count($expectedKeys) || array_diff(array_keys($input), $expectedKeys) !== []) {
            return PairingProblem::unavailable();
        }
        $decode = static fn (mixed $value): string|false => is_string($value) && preg_match('/^[A-Za-z0-9_-]+$/D', $value) === 1
            ? base64_decode(strtr($value, '-_', '+/').str_repeat('=', (4 - strlen($value) % 4) % 4), true)
            : false;
        $intentIdBytes = $decode($request->input('intent_id'));
        $isCanonicalIntentId = is_string($intentIdBytes)
            && strlen($intentIdBytes) === 16
            && rtrim(strtr(base64_encode($intentIdBytes), '+/', '-_'), '=') === $request->input('intent_id');
        $client = $decode($request->input('client_public_key'));
        $nonce = $decode($request->input('nonce'));
        $ciphertext = $decode($request->input('ciphertext'));
        $result = $isCanonicalIntentId && is_string($client) && is_string($nonce) && is_string($ciphertext)
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
}
