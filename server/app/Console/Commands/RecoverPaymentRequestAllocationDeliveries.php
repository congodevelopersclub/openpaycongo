<?php

namespace App\Console\Commands;

use App\Jobs\DispatchPaymentRequestAllocation;
use App\Models\PaymentRequestAllocationDelivery;
use Illuminate\Console\Command;

class RecoverPaymentRequestAllocationDeliveries extends Command
{
    protected $signature = 'payment-requests:recover-allocation-deliveries';

    protected $description = 'Re-enqueue durable payment-request allocation callbacks that have not been delivered.';

    public function handle(): int
    {
        PaymentRequestAllocationDelivery::query()->whereNull('dispatched_at')->orderBy('id')->eachById(
            fn (PaymentRequestAllocationDelivery $delivery) => DispatchPaymentRequestAllocation::dispatch($delivery->id),
        );

        return self::SUCCESS;
    }
}
