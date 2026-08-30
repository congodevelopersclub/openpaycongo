<?php

namespace App\PaymentRequests;

use App\Deposits\DepositKind;
use App\Events\CustomerCreditCreationPending;
use App\Models\CustomerCredit;
use App\Models\CustomerCreditPosting;
use App\Models\Deposit;
use App\Models\PaymentRequest;
use Carbon\CarbonImmutable;
use Illuminate\Database\QueryException;
use Illuminate\Support\Facades\DB;
use LogicException;

final class AllocatePendingPaymentRequests
{
    public function forDeposit(Deposit $deposit): void
    {
        $this->forDepositId($deposit->id);
    }

    public function forDepositId(string $depositId): void
    {
        for ($attempt = 1; $attempt <= 3; $attempt++) {
            try {
                DB::transaction(function () use ($depositId): void {
                    $deposit = Deposit::query()->lockForUpdate()->findOrFail($depositId);
                    if ($deposit->kind !== DepositKind::ProviderCredit->value
                        || CustomerCreditPosting::query()->where('deposit_id', $deposit->id)->lockForUpdate()->exists()) {
                        return;
                    }

                    $credit = CustomerCredit::query()
                        ->where('customer_id', $deposit->customer_id)
                        ->where('currency', $deposit->currency)
                        ->lockForUpdate()
                        ->first();
                    if ($credit === null) {
                        event(new CustomerCreditCreationPending($deposit->customer_id, $deposit->currency));
                        $credit = CustomerCredit::query()->create([
                            'customer_id' => $deposit->customer_id,
                            'currency' => $deposit->currency,
                            'available_minor' => 0,
                        ]);
                        $credit = CustomerCredit::query()->whereKey($credit->id)->lockForUpdate()->firstOrFail();
                    }

                    CustomerCreditPosting::query()->create([
                        'deposit_id' => $deposit->id,
                        'customer_credit_id' => $credit->id,
                        'amount_minor' => $deposit->amount_minor,
                    ]);
                    $credit->available_minor = (int) $credit->available_minor + (int) $deposit->amount_minor;
                    $credit->save();

                    $now = CarbonImmutable::now();
                    PaymentRequest::query()
                        ->where('customer_id', $deposit->customer_id)
                        ->where('currency', $deposit->currency)
                        ->where('status', PaymentRequestStatus::Pending)
                        ->where('expires_at', '<=', $now)
                        ->update(['status' => PaymentRequestStatus::Expired, 'updated_at' => $now]);

                    $pending = PaymentRequest::query()
                        ->where('customer_id', $deposit->customer_id)
                        ->where('currency', $deposit->currency)
                        ->where('status', PaymentRequestStatus::Pending)
                        ->where('expires_at', '>', $now)
                        ->orderBy('created_at')
                        ->orderBy('id')
                        ->lockForUpdate()
                        ->get();

                    foreach ($pending as $request) {
                        // The configured all-or-nothing policy intentionally preserves FIFO: do not skip an older shortfall.
                        if ((int) $credit->available_minor < (int) $request->remaining_minor) {
                            break;
                        }

                        $credit->available_minor = (int) $credit->available_minor - (int) $request->remaining_minor;
                        $request->remaining_minor = 0;
                        $request->status = PaymentRequestStatus::Charged->value;
                        $request->charged_at = $now;
                        $request->save();
                        app(RecordPaymentRequestAllocation::class)->record($request->id);
                    }

                    $credit->save();
                }, attempts: 3);

                return;
            } catch (QueryException $exception) {
                if ($attempt < 3 && $this->isUniqueContention($exception)) {
                    continue;
                }

                throw $exception;
            }
        }

        throw new LogicException('Customer-credit allocation retry limit was exhausted.');
    }

    private function isUniqueContention(QueryException $exception): bool
    {
        $driverErrorCode = $exception->errorInfo[1] ?? null;

        return in_array($exception->getCode(), ['23000', '23505', '40001'], true)
            || (is_int($driverErrorCode) || is_string($driverErrorCode))
            && in_array((string) $driverErrorCode, ['1020', '1213'], true);
    }
}
