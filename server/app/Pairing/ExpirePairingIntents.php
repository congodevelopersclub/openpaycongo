<?php

declare(strict_types=1);

namespace App\Pairing;

use App\Models\PairingIntent;
use Carbon\CarbonImmutable;
use Illuminate\Support\Facades\DB;

final class ExpirePairingIntents
{
    public const int MAX_PER_RUN = 100;

    public function execute(): int
    {
        $expired = 0;

        do {
            $page = $this->expirePage();
            $expired += $page;
        } while ($page === self::MAX_PER_RUN);

        return $expired;
    }

    private function expirePage(): int
    {
        return DB::transaction(function (): int {
            $now = CarbonImmutable::now('UTC');
            $intents = PairingIntent::query()
                ->lockForUpdate()
                ->whereIn('state', ['pending', 'pending_confirmation'])
                ->where('expires_at', '<=', $now)
                ->orderBy('expires_at')
                ->orderBy('id')
                ->limit(self::MAX_PER_RUN)
                ->get();

            foreach ($intents as $intent) {
                $intent->forceFill([
                    'state' => 'expired',
                    'protected_server_private_material' => '',
                    'pairing_secret_digest' => null,
                    'server_receive_key' => null,
                    'server_send_key' => null,
                    'short_authentication_code' => null,
                    'completion_request_digest' => null,
                    'completion_result' => null,
                ])->save();
            }

            return $intents->count();
        });
    }
}
