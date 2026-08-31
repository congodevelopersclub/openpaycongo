<?php

declare(strict_types=1);

namespace App\Console\Commands;

use App\Pairing\ExpirePairingIntents as ExpirePairingIntentsAction;
use Illuminate\Console\Command;

final class ExpirePairingIntents extends Command
{
    protected $signature = 'pairing:expire-intents';

    protected $description = 'Boundedly expire stale pairing intents and destroy their temporary material.';

    public function handle(ExpirePairingIntentsAction $expiry): int
    {
        $this->info('Expired '.$expiry->execute().' pairing intent(s).');

        return self::SUCCESS;
    }
}
