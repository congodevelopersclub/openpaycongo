<?php

namespace App\Jobs;

use App\Events\PaymentRequestAllocated;
use App\Models\PaymentRequestAllocationDelivery;
use Carbon\CarbonImmutable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;
use Illuminate\Support\Facades\DB;

class DispatchPaymentRequestAllocation implements ShouldQueue
{
    use Queueable;

    public function __construct(public readonly string $deliveryId) {}

    public function handle(): void
    {
        $paymentRequestId = DB::transaction(function (): ?string {
            $delivery = PaymentRequestAllocationDelivery::query()->lockForUpdate()->findOrFail($this->deliveryId);
            if ($delivery->dispatched_at !== null) {
                return null;
            }

            return $delivery->payment_request_id;
        });
        if ($paymentRequestId === null) {
            return;
        }

        event(new PaymentRequestAllocated($paymentRequestId));

        DB::transaction(function (): void {
            $delivery = PaymentRequestAllocationDelivery::query()->lockForUpdate()->findOrFail($this->deliveryId);
            if ($delivery->dispatched_at !== null) {
                return;
            }

            $delivery->dispatched_at = CarbonImmutable::now();
            $delivery->save();
        });
    }
}
