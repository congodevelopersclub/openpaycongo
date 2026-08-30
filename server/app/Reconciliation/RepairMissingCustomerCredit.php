<?php

namespace App\Reconciliation;

use App\Deposits\DepositKind;
use App\Models\CustomerCredit;
use App\Models\CustomerCreditPosting;
use App\Models\Deposit;
use App\Models\FinancialCorrectionAudit;
use App\Models\PaymentRequest;
use App\Models\User;
use App\PaymentRequests\AllocatePendingPaymentRequests;
use App\Security\FinancialOperatorMfaSession;
use Carbon\CarbonImmutable;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Gate;
use Illuminate\Validation\ValidationException;

final class RepairMissingCustomerCredit
{
    public function __construct(
        private readonly AllocatePendingPaymentRequests $allocation,
        private readonly ReconcileDeposit $reconciliation,
        private readonly FinancialOperatorMfaSession $mfa,
    ) {}

    public function repair(User $actor, Deposit $deposit, string $reasonCode, ?string $detail = null): CorrectionResult
    {
        Gate::forUser($actor)->authorize('correct', $deposit);
        $this->mfa->assertVerified($actor);
        if (! preg_match('/^[a-z][a-z0-9_]{0,63}$/', $reasonCode) || ($detail !== null && mb_strlen($detail) > 1000)) {
            throw ValidationException::withMessages(['reason_code' => 'A bounded correction reason code is required.']);
        }

        return DB::transaction(function () use ($actor, $deposit, $reasonCode, $detail): CorrectionResult {
            $deposit = Deposit::query()->lockForUpdate()->findOrFail($deposit->id);
            if (CustomerCreditPosting::query()->where('deposit_id', $deposit->id)->exists()) {
                if ($this->hasMatchingReplayIntent($deposit, $actor, $reasonCode, $detail)
                    && $this->reconciliation->report($deposit)->isReconciled) {
                    return new CorrectionResult(false);
                }

                throw ValidationException::withMessages(['deposit' => 'Existing customer credit posting does not match a reconciled correction intent.']);
            }
            $discrepancies = $this->reconciliation->report($deposit)->discrepancies;
            if ($deposit->kind !== DepositKind::ProviderCredit->value
                || array_diff($discrepancies, ['customer_credit_posting', 'customer_credit_balance']) !== []) {
                throw ValidationException::withMessages(['deposit' => 'This discrepancy cannot be repaired automatically.']);
            }
            $credit = CustomerCredit::query()
                ->where('customer_id', $deposit->customer_id)
                ->where('currency', $deposit->currency)
                ->lockForUpdate()
                ->first();
            $posted = CustomerCreditPosting::query()
                ->whereHas('customerCredit', fn ($query) => $query->where('customer_id', $deposit->customer_id)->where('currency', $deposit->currency))
                ->sum('amount_minor');
            $allocated = PaymentRequest::query()
                ->where('customer_id', $deposit->customer_id)
                ->where('currency', $deposit->currency)
                ->where('status', 'charged')
                ->sum('amount_minor');
            if ($credit === null || (int) $credit->available_minor !== (int) $posted - (int) $allocated) {
                throw ValidationException::withMessages(['deposit' => 'This discrepancy cannot be repaired automatically.']);
            }

            $this->allocation->forDeposit($deposit);
            FinancialCorrectionAudit::query()->create([
                'deposit_id' => $deposit->id,
                'organization_id' => $deposit->organization_id,
                'actor_user_id' => $actor->id,
                'correction' => 'repair_missing_customer_credit',
                'reason_code' => $reasonCode,
                'detail' => $detail,
                'recorded_at' => CarbonImmutable::now(),
            ]);

            return new CorrectionResult(true);
        });
    }

    private function hasMatchingReplayIntent(Deposit $deposit, User $actor, string $reasonCode, ?string $detail): bool
    {
        $audits = FinancialCorrectionAudit::query()
            ->where('deposit_id', $deposit->id)
            ->where('correction', 'repair_missing_customer_credit')
            ->get();
        $audit = $audits->first();

        return $audit !== null
            && $audits->count() === 1
            && $audit->organization_id === $deposit->organization_id
            && (int) $audit->actor_user_id === (int) $actor->id
            && $audit->reason_code === $reasonCode
            && $audit->detail === $detail;
    }
}
