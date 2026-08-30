<?php

namespace App\Console\Commands;

use App\Setup\ProvisionLegacyFinancialOperator as ProvisionAction;
use Illuminate\Console\Command;
use Throwable;

final class ProvisionLegacyFinancialOperator extends Command
{
    protected $signature = 'openpay:provision-legacy-operator
                            {user_id : Numeric local user ID to provision}
                            {--force : Confirm this locally authorized legacy operation}';

    protected $description = 'Provision one legacy user as the financial operator without reopening public setup.';

    public function handle(ProvisionAction $provision): int
    {
        $userId = filter_var($this->argument('user_id'), FILTER_VALIDATE_INT, ['options' => ['min_range' => 1]]);

        if ($userId === false || ! $this->option('force')) {
            $this->error('A numeric user ID and --force are required for legacy operator provisioning.');

            return self::FAILURE;
        }

        try {
            $provision->provision($userId);
        } catch (Throwable) {
            $this->error('Legacy operator provisioning was refused.');

            return self::FAILURE;
        }

        $this->info('Legacy financial operator provisioned. The user must complete TOTP enrollment and recovery-code acknowledgement before operations.');

        return self::SUCCESS;
    }
}
