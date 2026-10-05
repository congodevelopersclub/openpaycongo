<?php

declare(strict_types=1);

namespace App\Http\Controllers;

use App\Models\OperatorSmsPatternRelease;
use App\Models\SourceInstallation;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

/**
 * Delivery boundary for immutable developer-approved parser releases.
 * The mobile client still verifies every signature and binding locally; this
 * endpoint deliberately returns no interpretation evidence or payment data.
 */
final class ListOperatorSmsPatternReleasesController
{
    public function __invoke(Request $request): JsonResponse
    {
        /** @var SourceInstallation $installation */
        $installation = $request->user('mobile');

        $releases = OperatorSmsPatternRelease::query()
            ->where('organization_id', $installation->organization_id)
            ->where('expires_at', '>', now('UTC'))
            ->orderBy('issued_at')
            ->orderBy('id')
            ->limit(100)
            ->get(['id', 'encoded_release'])
            ->map(static fn (OperatorSmsPatternRelease $release): array => [
                'release_id' => $release->id,
                'encoded_release' => $release->encoded_release,
            ])
            ->all();

        return response()->json(['releases' => $releases], 200, ['cache-control' => 'no-store']);
    }
}
