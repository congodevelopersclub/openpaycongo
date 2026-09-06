<?php

declare(strict_types=1);

namespace App\Console\Commands;

use App\OperatorSms\PurgeExpiredOperatorSmsInterpretationRequests as PurgeRequests;
use Illuminate\Console\Command;

final class PurgeExpiredOperatorSmsInterpretationRequests extends Command
{
    protected $signature = 'operator-sms:purge-expired-interpretation-requests';

    protected $description = 'Destroy expired user-authorized raw operator SMS evidence.';

    public function handle(PurgeRequests $purge): int
    {
        $this->info('Purged '.$purge->execute().' expired operator SMS interpretation request(s).');

        return self::SUCCESS;
    }
}
