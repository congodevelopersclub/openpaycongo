<?php

namespace App\Console\Commands;

use App\Deposits\DepositKind;
use App\Models\Deposit;
use App\PaymentRequests\AllocatePendingPaymentRequests;
use Illuminate\Console\Command;

final class RecoverPaymentRequestCredits extends Command
{
    protected $signature = 'payment-requests:recover-credit';

    protected $description = 'Idempotently reconcile committed provider credit that was not posted by the queue listener.';

    public function handle(AllocatePendingPaymentRequests $allocation): int
    {
        Deposit::query()
            ->where('kind', DepositKind::ProviderCredit->value)
            ->whereDoesntHave('customerCreditPosting')
            ->orderBy('id')
            ->eachById(function (Deposit $deposit) use ($allocation): void {
                $allocation->forDeposit($deposit);
            }, 100);

        return self::SUCCESS;
    }
}
