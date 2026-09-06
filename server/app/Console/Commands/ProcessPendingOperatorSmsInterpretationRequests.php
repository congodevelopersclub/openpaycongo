<?php

declare(strict_types=1);

namespace App\Console\Commands;

use App\OperatorSms\ProcessPendingOperatorSmsInterpretationRequests as ProcessRequests;
use Illuminate\Console\Command;

final class ProcessPendingOperatorSmsInterpretationRequests extends Command
{
    protected $signature = 'operator-sms:propose-pending-patterns {--limit=25}';

    protected $description = 'Create review-only proposals from explicit, unexpired operator SMS evidence.';

    public function handle(ProcessRequests $processor): int
    {
        $limit = $this->option('limit');
        $count = $processor->execute(is_numeric($limit) ? (int) $limit : 25);
        $this->info('Processed '.$count.' operator SMS interpretation request(s).');

        return self::SUCCESS;
    }
}
