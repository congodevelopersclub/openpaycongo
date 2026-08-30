<?php

namespace App\PaymentRequests;

use App\Jobs\DispatchPaymentRequestAllocation;
use App\Models\PaymentRequestAllocationDelivery;

final class RecordPaymentRequestAllocation
{
    public function record(string $paymentRequestId): void
    {
        $delivery = PaymentRequestAllocationDelivery::query()->firstOrCreate([
            'payment_request_id' => $paymentRequestId,
        ]);

        DispatchPaymentRequestAllocation::dispatch($delivery->id)->afterCommit();
    }
}
