<?php

namespace App\Listeners;

use App\Events\ProviderDepositRecorded;
use App\PaymentRequests\AllocatePendingPaymentRequests;
use Illuminate\Contracts\Queue\ShouldQueue;

final class AllocatePendingPaymentRequestsForDeposit implements ShouldQueue
{
    public bool $afterCommit = true;

    public function __construct(private readonly AllocatePendingPaymentRequests $allocation) {}

    public function handle(ProviderDepositRecorded $event): void
    {
        $this->allocation->forDepositId($event->depositId);
    }
}
