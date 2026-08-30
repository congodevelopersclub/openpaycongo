<?php

namespace App\Jobs;

use App\Events\PaymentRequestAllocated;
use App\Models\PaymentRequestAllocationDelivery;
use Carbon\CarbonImmutable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use Throwable;

class DispatchPaymentRequestAllocation implements ShouldQueue
{
    use Queueable;

    public function __construct(public readonly string $deliveryId) {}

    public function handle(): void
    {
        $claimToken = (string) Str::uuid();
        $paymentRequestId = DB::transaction(function () use ($claimToken): ?string {
            $delivery = PaymentRequestAllocationDelivery::query()->lockForUpdate()->findOrFail($this->deliveryId);
            if ($delivery->dispatched_at !== null) {
                return null;
            }
            $now = CarbonImmutable::now();
            if ($delivery->claimed_at !== null && CarbonImmutable::parse($delivery->claimed_at)->greaterThan($now->subMinutes(5))) {
                return null;
            }

            $delivery->claimed_at = $now;
            $delivery->claim_token = $claimToken;
            $delivery->save();

            return $delivery->payment_request_id;
        });
        if ($paymentRequestId === null) {
            return;
        }

        try {
            event(new PaymentRequestAllocated($paymentRequestId));
        } catch (Throwable $exception) {
            $this->releaseClaim($claimToken);

            throw $exception;
        }

        DB::transaction(function () use ($claimToken): void {
            $delivery = PaymentRequestAllocationDelivery::query()->lockForUpdate()->findOrFail($this->deliveryId);
            if ($delivery->dispatched_at !== null || $delivery->claim_token !== $claimToken) {
                return;
            }

            $delivery->dispatched_at = CarbonImmutable::now();
            $delivery->claimed_at = null;
            $delivery->claim_token = null;
            $delivery->save();
        });
    }

    private function releaseClaim(string $claimToken): void
    {
        DB::transaction(function () use ($claimToken): void {
            $delivery = PaymentRequestAllocationDelivery::query()->lockForUpdate()->findOrFail($this->deliveryId);
            if ($delivery->dispatched_at !== null || $delivery->claim_token !== $claimToken) {
                return;
            }

            $delivery->claimed_at = null;
            $delivery->claim_token = null;
            $delivery->save();
        });
    }
}
