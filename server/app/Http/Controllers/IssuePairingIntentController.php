<?php

declare(strict_types=1);

namespace App\Http\Controllers;

use App\Http\Requests\IssuePairingIntentRequest;
use App\Http\Resources\PairingIntentQrResource;
use App\Pairing\IssuePendingPairingIntent;
use Illuminate\Http\JsonResponse;

final class IssuePairingIntentController
{
    public function __invoke(
        IssuePairingIntentRequest $request,
        IssuePendingPairingIntent $issue,
    ): JsonResponse {
        $issued = $issue->execute(
            organizationId: $request->organizationId(),
            lifetimeSeconds: $request->integer('lifetime_seconds'),
        );

        return response()->json(
            (new PairingIntentQrResource($issued))->resolve($request),
            201,
            ['cache-control' => 'private, no-store'],
        );
    }
}
