<?php

namespace App\Reconciliation;

use App\Deposits\DepositKind;
use App\Models\CustomerCredit;
use App\Models\CustomerCreditPosting;
use App\Models\Deposit;
use App\Models\LedgerEntry;
use App\Models\PaymentRequest;

final class ReconcileDeposit
{
    public function report(Deposit $deposit): ReconciliationReport
    {
        $deposit->loadMissing('ledgerEntries.reversesLedgerEntry');
        $discrepancies = [];
        $entries = $deposit->ledgerEntries;

        if ($entries->count() !== 2) {
            $discrepancies[] = 'ledger_entry_count';
        }
        if ((int) $entries->sum('debit_minor') !== (int) $entries->sum('credit_minor')) {
            $discrepancies[] = 'ledger_not_balanced';
        }
        if ($entries->contains(fn ($entry): bool => $entry->organization_id !== $deposit->organization_id || $entry->currency !== $deposit->currency)) {
            $discrepancies[] = 'ledger_scope_mismatch';
        }
        if (! $this->hasExpectedLedgerShape($deposit)) {
            $discrepancies[] = 'ledger_entry_shape';
        }

        $expectedPosting = match ($deposit->kind) {
            DepositKind::ProviderCredit->value => (int) $deposit->amount_minor,
            DepositKind::ProviderReversal->value => -(int) $deposit->amount_minor,
            default => null,
        };
        $posting = CustomerCreditPosting::query()->where('deposit_id', $deposit->id)->first();
        if ($expectedPosting !== null && ($posting === null || (int) $posting->amount_minor !== $expectedPosting)) {
            $discrepancies[] = 'customer_credit_posting';
        }

        if ($deposit->kind === DepositKind::ProviderReversal->value) {
            if ($deposit->reversedDeposit === null || $deposit->reversal_reason === null || $deposit->reversed_by_user_id === null) {
                $discrepancies[] = 'reversal_evidence';
            }
            if ($entries->contains(fn ($entry): bool => $entry->reverses_ledger_entry_id === null)
                || ! $this->hasOriginalLedgerLinkage($deposit)) {
                $discrepancies[] = 'reversal_ledger_linkage';
            }
        }

        $posted = CustomerCreditPosting::query()
            ->whereHas('customerCredit', fn ($query) => $query->where('customer_id', $deposit->customer_id)->where('currency', $deposit->currency))
            ->sum('amount_minor');
        $allocated = PaymentRequest::query()
            ->where('customer_id', $deposit->customer_id)
            ->where('currency', $deposit->currency)
            ->where('status', 'charged')
            ->sum('amount_minor');
        $available = CustomerCredit::query()->where('customer_id', $deposit->customer_id)->where('currency', $deposit->currency)->value('available_minor');
        if ($available === null || (int) $available !== (int) $posted - (int) $allocated) {
            $discrepancies[] = 'customer_credit_balance';
        }

        return new ReconciliationReport($discrepancies === [], $discrepancies);
    }

    private function hasExpectedLedgerShape(Deposit $deposit): bool
    {
        $expected = $deposit->kind === DepositKind::ProviderReversal->value
            ? [['customer_credit', (int) $deposit->amount_minor, 0], ['provider_receivable', 0, (int) $deposit->amount_minor]]
            : [['provider_receivable', (int) $deposit->amount_minor, 0], ['customer_credit', 0, (int) $deposit->amount_minor]];

        return collect($expected)->every(fn (array $entry): bool => $deposit->ledgerEntries->contains(
            fn (LedgerEntry $actual): bool => $actual->account === $entry[0]
                && (int) $actual->debit_minor === $entry[1]
                && (int) $actual->credit_minor === $entry[2],
        ));
    }

    private function hasOriginalLedgerLinkage(Deposit $reversal): bool
    {
        return $reversal->ledgerEntries->every(function (LedgerEntry $entry) use ($reversal): bool {
            $original = $entry->reversesLedgerEntry;

            return $original !== null
                && $original->deposit_id === $reversal->reverses_deposit_id
                && $original->account === $entry->account;
        });
    }
}
