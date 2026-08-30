<?php

namespace App\Reconciliation;

use App\Deposits\DepositKind;
use App\Models\CustomerCreditPosting;
use App\Models\Deposit;
use App\Models\FinancialCorrectionAudit;
use App\Models\User;
use App\PaymentRequests\AllocatePendingPaymentRequests;
use Carbon\CarbonImmutable;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Gate;
use Illuminate\Validation\ValidationException;

final class RepairMissingCustomerCredit
{
    public function __construct(
        private readonly AllocatePendingPaymentRequests $allocation,
        private readonly ReconcileDeposit $reconciliation,
    ) {}

    public function repair(User $actor, Deposit $deposit, string $reason): CorrectionResult
    {
        Gate::forUser($actor)->authorize('correct', $deposit);
        if (trim($reason) === '' || mb_strlen($reason) > 255) {
            throw ValidationException::withMessages(['reason' => 'A bounded correction reason is required.']);
        }

        return DB::transaction(function () use ($actor, $deposit, $reason): CorrectionResult {
            $deposit = Deposit::query()->lockForUpdate()->findOrFail($deposit->id);
            if (CustomerCreditPosting::query()->where('deposit_id', $deposit->id)->exists()) {
                return new CorrectionResult(false);
            }
            $discrepancies = $this->reconciliation->report($deposit)->discrepancies;
            if ($deposit->kind !== DepositKind::ProviderCredit->value
                || array_diff($discrepancies, ['customer_credit_posting', 'customer_credit_balance']) !== []) {
                throw ValidationException::withMessages(['deposit' => 'This discrepancy cannot be repaired automatically.']);
            }

            $this->allocation->forDeposit($deposit);
            FinancialCorrectionAudit::query()->create([
                'deposit_id' => $deposit->id,
                'organization_id' => $deposit->organization_id,
                'actor_user_id' => $actor->id,
                'correction' => 'repair_missing_customer_credit',
                'reason' => trim($reason),
                'recorded_at' => CarbonImmutable::now(),
            ]);

            return new CorrectionResult(true);
        });
    }
}
