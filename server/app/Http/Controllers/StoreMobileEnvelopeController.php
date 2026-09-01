<?php

declare(strict_types=1);

namespace App\Http\Controllers;

use App\MobileEnvelopes\ReceiveMobileEnvelope;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Throwable;

final class StoreMobileEnvelopeController
{
    public function __invoke(Request $request, ReceiveMobileEnvelope $envelopes): JsonResponse
    {
        try {
            if (! $request->isJson()) {
                throw new \RuntimeException;
            }

            $response = $envelopes->receive($request->json()->all());
        } catch (Throwable) {
            return response()->json(['code' => 'mobile_envelope_unavailable'], 404, ['Cache-Control' => 'no-store, private']);
        }

        return response()->json($response->outer(), $response->status, ['Cache-Control' => 'no-store, private']);
    }
}
