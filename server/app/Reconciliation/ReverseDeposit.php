<?php

namespace App\Reconciliation;

use App\Deposits\DepositKind;
use App\Deposits\ReversalResult;
use App\Deposits\ReverseProviderDepositResult;
use App\Events\CustomerCreditCreationPending;
use App\Models\CustomerCredit;
use App\Models\CustomerCreditPosting;
use App\Models\Deposit;
use App\Models\FinancialCorrectionAudit;
use App\Models\LedgerEntry;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Gate;
use Illuminate\Validation\ValidationException;

final class ReverseDeposit
{
    public function reverse(User $actor, Deposit $deposit, string $reasonCode, ?string $detail = null): ReverseProviderDepositResult
    {
        Gate::forUser($actor)->authorize('correct', $deposit);
        if (! preg_match('/^[a-z][a-z0-9_]{0,63}$/', $reasonCode) || ($detail !== null && mb_strlen($detail) > 1000)) {
            throw ValidationException::withMessages(['reason_code' => 'A bounded correction reason code is required.']);
        }

        return DB::transaction(function () use ($actor, $deposit, $reasonCode, $detail): ReverseProviderDepositResult {
            $original = Deposit::query()->lockForUpdate()->findOrFail($deposit->id);
            if ($original->kind !== DepositKind::ProviderCredit->value) {
                throw ValidationException::withMessages(['deposit' => 'Deposit cannot be reversed.']);
            }
            $reversal = Deposit::query()->where('reverses_deposit_id', $original->id)->first();
            if ($reversal === null) {
                $recordedAt = CarbonImmutable::now();
                $reversal = Deposit::query()->create([
                    'organization_id' => $original->organization_id, 'customer_id' => $original->customer_id, 'source_installation_id' => $original->source_installation_id,
                    'reverses_deposit_id' => $original->id, 'reversal_reason_code' => $reasonCode, 'reversal_detail' => $detail,
                    'reversed_by_user_id' => $actor->id, 'kind' => DepositKind::ProviderReversal->value, 'amount_minor' => $original->amount_minor,
                    'currency' => $original->currency, 'received_at' => $recordedAt,
                    'idempotency_digest' => hash('sha256', 'reversal:'.$original->organization_id.':'.$original->id), 'idempotency_key_version' => 'reconciliation',
                ]);
                $originalEntries = $original->ledgerEntries()->get()->keyBy('account');
                foreach ([['customer_credit', $reversal->amount_minor, 0], ['provider_receivable', 0, $reversal->amount_minor]] as [$account, $debit, $credit]) {
                    LedgerEntry::query()->create(['deposit_id' => $reversal->id, 'organization_id' => $reversal->organization_id, 'currency' => $reversal->currency, 'recorded_at' => $recordedAt, 'reverses_ledger_entry_id' => $originalEntries->get($account)?->id, 'account' => $account, 'debit_minor' => $debit, 'credit_minor' => $credit]);
                }
                $customerCredit = CustomerCredit::query()->where('customer_id', $reversal->customer_id)->where('currency', $reversal->currency)->lockForUpdate()->first();
                if ($customerCredit === null) {
                    event(new CustomerCreditCreationPending($reversal->customer_id, $reversal->currency));
                    $customerCredit = CustomerCredit::query()->create(['customer_id' => $reversal->customer_id, 'currency' => $reversal->currency, 'available_minor' => 0]);
                }
                $customerCredit->available_minor = (int) $customerCredit->available_minor - (int) $reversal->amount_minor;
                $customerCredit->save();
                CustomerCreditPosting::query()->create(['deposit_id' => $reversal->id, 'customer_credit_id' => $customerCredit->id, 'amount_minor' => -(int) $reversal->amount_minor]);
            }
            $result = new ReverseProviderDepositResult($reversal->wasRecentlyCreated ? ReversalResult::Reversed : ReversalResult::Replayed, $reversal);
            FinancialCorrectionAudit::query()->firstOrCreate(
                ['deposit_id' => $result->deposit->id, 'correction' => 'reverse_deposit'],
                [
                    'organization_id' => $result->deposit->organization_id,
                    'actor_user_id' => $actor->id,
                    'reason_code' => $reasonCode,
                    'detail' => $detail,
                    'recorded_at' => CarbonImmutable::now(),
                ],
            );

            return $result;
        });
    }
}
