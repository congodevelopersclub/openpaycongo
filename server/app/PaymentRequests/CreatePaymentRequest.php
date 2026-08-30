<?php

namespace App\PaymentRequests;

use App\Events\PaymentRequestAllocated;
use App\Models\Customer;
use App\Models\CustomerCredit;
use App\Models\PaymentRequest;
use Carbon\CarbonImmutable;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use InvalidArgumentException;

final class CreatePaymentRequest
{
    public function create(string $customerId, int $amountMinor, string $currency): PaymentRequest
    {
        $currency = strtoupper($currency);
        if (! Str::isUuid($customerId)
            || $amountMinor < 1
            || preg_match('/^[A-Z]{3}$/D', $currency) !== 1
            || ! in_array($currency, (array) config('deposits.supported_currencies'), true)) {
            throw new InvalidArgumentException('Invalid payment request.');
        }

        return DB::transaction(function () use ($customerId, $amountMinor, $currency): PaymentRequest {
            Customer::query()->lockForUpdate()->findOrFail($customerId);
            $credit = CustomerCredit::query()
                ->where('customer_id', $customerId)
                ->where('currency', $currency)
                ->lockForUpdate()
                ->first();
            $now = CarbonImmutable::now();

            if ($credit !== null) {
                PaymentRequest::query()
                    ->where('customer_id', $customerId)
                    ->where('currency', $currency)
                    ->where('status', PaymentRequestStatus::Pending)
                    ->where('expires_at', '<=', $now)
                    ->update(['status' => PaymentRequestStatus::Expired, 'updated_at' => $now]);

                $olderRequests = PaymentRequest::query()
                    ->where('customer_id', $customerId)
                    ->where('currency', $currency)
                    ->where('status', PaymentRequestStatus::Pending)
                    ->where('expires_at', '>', $now)
                    ->orderBy('created_at')
                    ->orderBy('id')
                    ->lockForUpdate()
                    ->get();

                $olderShortfall = false;
                foreach ($olderRequests as $olderRequest) {
                    if ((int) $credit->available_minor < (int) $olderRequest->remaining_minor) {
                        $olderShortfall = true;
                        break;
                    }

                    $credit->available_minor = (int) $credit->available_minor - (int) $olderRequest->remaining_minor;
                    $olderRequest->remaining_minor = 0;
                    $olderRequest->status = PaymentRequestStatus::Charged->value;
                    $olderRequest->charged_at = $now;
                    $olderRequest->save();
                    event(new PaymentRequestAllocated($olderRequest->id));
                }

                $credit->save();

                if (! $olderShortfall && (int) $credit->available_minor >= $amountMinor) {
                    $credit->available_minor = (int) $credit->available_minor - $amountMinor;
                    $credit->save();
                    $request = PaymentRequest::query()->create([
                        'customer_id' => $customerId,
                        'currency' => $currency,
                        'amount_minor' => $amountMinor,
                        'remaining_minor' => 0,
                        'status' => PaymentRequestStatus::Charged,
                        'expires_at' => $now->addDays($this->expiryDays()),
                        'charged_at' => $now,
                    ]);
                    event(new PaymentRequestAllocated($request->id));

                    return $request;
                }
            }

            return PaymentRequest::query()->create([
                'customer_id' => $customerId,
                'currency' => $currency,
                'amount_minor' => $amountMinor,
                'remaining_minor' => $amountMinor,
                'status' => PaymentRequestStatus::Pending,
                'expires_at' => $now->addDays($this->expiryDays()),
            ]);
        }, attempts: 3);
    }

    private function expiryDays(): int
    {
        $days = config('payment_requests.pending_expiry_days');

        return is_int($days) && $days >= 30 ? $days : 90;
    }
}
