<?php

declare(strict_types=1);

namespace App\OperatorSms;

use App\Models\OperatorSmsInterpretationRequest;
use Carbon\CarbonImmutable;
use Illuminate\Support\Facades\DB;

/** Destroys user-authorized raw SMS evidence after its bounded review window. */
final class PurgeExpiredOperatorSmsInterpretationRequests
{
    public const int MAX_PER_RUN = 100;

    public function execute(): int
    {
        $purged = 0;

        do {
            $page = $this->purgePage();
            $purged += $page;
        } while ($page === self::MAX_PER_RUN);

        return $purged;
    }

    private function purgePage(): int
    {
        return DB::transaction(function (): int {
            $requests = OperatorSmsInterpretationRequest::query()
                ->lockForUpdate()
                ->where('expires_at', '<=', CarbonImmutable::now('UTC'))
                ->orderBy('expires_at')
                ->orderBy('id')
                ->limit(self::MAX_PER_RUN)
                ->get();

            foreach ($requests as $request) {
                $request->delete();
            }

            return $requests->count();
        });
    }
}
