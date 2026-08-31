<?php

declare(strict_types=1);

namespace App\Http\Responses;

use Illuminate\Http\JsonResponse;
use Illuminate\Support\Str;

final class PairingProblem
{
    public static function requestFailed(int $status): JsonResponse
    {
        return self::response(
            status: $status,
            type: 'https://openpaycongo.example/problems/pairing-request-failed',
            title: 'Pairing request failed',
            code: 'pairing_request_failed',
        );
    }

    public static function rateLimited(?string $retryAfter): JsonResponse
    {
        return self::response(
            status: 429,
            type: 'https://openpaycongo.example/problems/pairing-rate-limited',
            title: 'Pairing request rate limited',
            code: 'pairing_rate_limited',
            retryAfter: $retryAfter,
        );
    }

    private static function response(
        int $status,
        string $type,
        string $title,
        string $code,
        ?string $retryAfter = null,
    ): JsonResponse {
        $response = response()->json([
            'type' => $type,
            'title' => $title,
            'status' => $status,
            'code' => $code,
            'request_id' => (string) Str::uuid(),
        ], $status);

        $response->headers->set('Cache-Control', 'private, no-store');
        $response->headers->set('Content-Type', 'application/problem+json');

        if ($retryAfter !== null) {
            $response->headers->set('Retry-After', $retryAfter);
        }

        return $response;
    }
}
