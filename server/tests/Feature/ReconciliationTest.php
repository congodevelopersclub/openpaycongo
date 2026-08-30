<?php

namespace Tests\Feature;

use App\Deposits\ProviderTransfer;
use App\Deposits\RecordProviderDeposit;
use App\Models\Customer;
use App\Models\CustomerCredit;
use App\Models\CustomerCreditPosting;
use App\Models\LedgerEntry;
use App\Models\User;
use App\Reconciliation\ReconcileDeposit;
use App\Reconciliation\RepairMissingCustomerCredit;
use App\Reconciliation\ReverseDeposit;
use Illuminate\Auth\Access\AuthorizationException;
use Illuminate\Database\QueryException;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use Illuminate\Validation\ValidationException;
use Tests\TestCase;

final class ReconciliationTest extends TestCase
{
    use RefreshDatabase;

    public function test_an_operator_can_reconcile_a_reversal_without_rewriting_history(): void
    {
        $operator = User::factory()->create(['is_financial_operator' => true]);
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;

        $reversal = app(ReverseDeposit::class)->reverse($operator, $deposit, 'provider_correction');
        $report = app(ReconcileDeposit::class)->report($reversal->deposit);

        self::assertTrue($report->isReconciled);
        self::assertSame([], $report->discrepancies);
        self::assertDatabaseHas('deposits', [
            'id' => $reversal->deposit->id,
            'reverses_deposit_id' => $deposit->id,
            'reversal_reason_code' => 'provider_correction',
            'reversed_by_user_id' => $operator->id,
        ]);
        self::assertDatabaseHas('customer_credit_postings', [
            'deposit_id' => $reversal->deposit->id,
            'amount_minor' => -12500,
        ]);
        self::assertDatabaseCount('financial_correction_audits', 1);
        self::assertSame(2, LedgerEntry::query()->where('deposit_id', $reversal->deposit->id)->whereNotNull('reverses_ledger_entry_id')->count());
    }

    public function test_an_operator_can_repair_a_missing_credit_posting_once_and_the_replay_is_a_no_op(): void
    {
        $operator = User::factory()->create(['is_financial_operator' => true]);
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        CustomerCreditPosting::query()->where('deposit_id', $deposit->id)->delete();
        CustomerCredit::query()->where('customer_id', $deposit->customer_id)->where('currency', $deposit->currency)->update(['available_minor' => 0]);

        $repair = app(RepairMissingCustomerCredit::class);
        $first = $repair->repair($operator, $deposit, 'missing_credit_posting');
        $replay = $repair->repair($operator, $deposit, 'missing_credit_posting');

        self::assertTrue($first->repaired);
        self::assertFalse($replay->repaired);
        self::assertTrue(app(ReconcileDeposit::class)->report($deposit)->isReconciled);
        self::assertDatabaseCount('financial_correction_audits', 1);
    }

    public function test_a_non_operator_cannot_reverse_or_repair_financial_records(): void
    {
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        $operator = User::factory()->create(['is_financial_operator' => false]);

        $this->expectException(AuthorizationException::class);
        app(ReverseDeposit::class)->reverse($operator, $deposit, 'provider_correction');
    }

    public function test_the_privileged_report_resource_exposes_only_reconciliation_state(): void
    {
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        $operator = User::factory()->create(['is_financial_operator' => true]);

        $this->actingAs($operator)
            ->getJson('/reconciliation/deposits/'.$deposit->id)
            ->assertOk()
            ->assertExactJson(['data' => ['is_reconciled' => true, 'discrepancies' => []]]);

        $this->actingAs(User::factory()->create(['is_financial_operator' => false]))
            ->getJson('/reconciliation/deposits/'.$deposit->id)
            ->assertForbidden();
    }

    public function test_reconciliation_surfaces_missing_original_ledger_linkage_and_the_database_rejects_duplicates(): void
    {
        $operator = User::factory()->create(['is_financial_operator' => true]);
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        $reversal = app(ReverseDeposit::class)->reverse($operator, $deposit, 'provider_correction')->deposit;
        $entry = LedgerEntry::query()->where('deposit_id', $reversal->id)->firstOrFail();

        DB::table('ledger_entries')->where('id', $entry->id)->update(['reverses_ledger_entry_id' => null]);

        self::assertContains('reversal_ledger_linkage', app(ReconcileDeposit::class)->report($reversal)->discrepancies);
        $this->expectException(QueryException::class);
        DB::table('ledger_entries')->insert([
            'id' => Str::uuid()->toString(),
            'deposit_id' => $reversal->id,
            'organization_id' => $reversal->organization_id,
            'reverses_ledger_entry_id' => LedgerEntry::query()->where('deposit_id', $reversal->id)->whereNotNull('reverses_ledger_entry_id')->value('reverses_ledger_entry_id'),
            'account' => 'test_duplicate',
            'debit_minor' => 0,
            'credit_minor' => 0,
            'currency' => $reversal->currency,
            'recorded_at' => now(),
            'created_at' => now(),
            'updated_at' => now(),
        ]);
    }

    public function test_repair_rejects_a_missing_posting_when_the_credit_balance_is_not_exactly_short(): void
    {
        $operator = User::factory()->create(['is_financial_operator' => true]);
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        CustomerCreditPosting::query()->where('deposit_id', $deposit->id)->delete();

        $this->expectException(ValidationException::class);
        app(RepairMissingCustomerCredit::class)->repair($operator, $deposit, 'missing_credit_posting');
    }

    public function test_reconciliation_surfaces_mis_scoped_postings_and_partial_reversals(): void
    {
        $operator = User::factory()->create(['is_financial_operator' => true]);
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        $other = Customer::query()->create([
            'organization_id' => $deposit->organization_id,
            'private_lookup_digest' => hash('sha256', 'other-customer'),
        ]);
        $otherCredit = CustomerCredit::query()->create(['customer_id' => $other->id, 'currency' => $deposit->currency, 'available_minor' => 0]);
        CustomerCreditPosting::query()->where('deposit_id', $deposit->id)->update(['customer_credit_id' => $otherCredit->id]);
        CustomerCredit::query()->where('customer_id', $deposit->customer_id)->where('currency', $deposit->currency)->update(['available_minor' => 0]);

        self::assertContains('customer_credit_posting_scope', app(ReconcileDeposit::class)->report($deposit)->discrepancies);

        $originalCredit = CustomerCredit::query()->where('customer_id', $deposit->customer_id)->where('currency', $deposit->currency)->firstOrFail();
        CustomerCreditPosting::query()->where('deposit_id', $deposit->id)->update(['customer_credit_id' => $originalCredit->id]);
        $originalCredit->available_minor = $deposit->amount_minor;
        $originalCredit->save();
        $reversal = app(ReverseDeposit::class)->reverse($operator, $deposit, 'provider_correction')->deposit;
        DB::table('deposits')->where('id', $reversal->id)->update(['amount_minor' => 6000]);
        DB::table('ledger_entries')->where('deposit_id', $reversal->id)->where('account', 'customer_credit')->update(['debit_minor' => 6000]);
        DB::table('ledger_entries')->where('deposit_id', $reversal->id)->where('account', 'provider_receivable')->update(['credit_minor' => 6000]);
        DB::table('customer_credit_postings')->where('deposit_id', $reversal->id)->update(['amount_minor' => -6000]);
        CustomerCredit::query()->where('customer_id', $deposit->customer_id)->where('currency', $deposit->currency)->update(['available_minor' => -6000]);

        self::assertContains('reversal_evidence', app(ReconcileDeposit::class)->report($reversal)->discrepancies);
        self::assertContains('reversal_ledger_linkage', app(ReconcileDeposit::class)->report($reversal)->discrepancies);
    }

    public function test_reversal_refuses_an_unreconciled_original_and_legacy_replay_without_evidence(): void
    {
        $operator = User::factory()->create(['is_financial_operator' => true]);
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        CustomerCreditPosting::query()->where('deposit_id', $deposit->id)->delete();

        try {
            app(ReverseDeposit::class)->reverse($operator, $deposit, 'provider_correction');
            self::fail('An unreconciled original must not be reversed.');
        } catch (ValidationException) {
            self::assertDatabaseCount('financial_correction_audits', 0);
        }

        CustomerCredit::query()->where('customer_id', $deposit->customer_id)->where('currency', $deposit->currency)->update(['available_minor' => 0]);
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer('legacy-replay'))->deposit;
        $reversal = app(ReverseDeposit::class)->reverse($operator, $deposit, 'provider_correction')->deposit;
        DB::table('financial_correction_audits')->where('deposit_id', $reversal->id)->delete();

        $this->expectException(ValidationException::class);
        app(ReverseDeposit::class)->reverse($operator, $deposit, 'provider_correction');
    }

    public function test_reconciliation_rejects_an_unknown_deposit_kind(): void
    {
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        DB::table('deposits')->where('id', $deposit->id)->update(['kind' => 'unknown']);

        self::assertContains('unsupported_deposit_kind', app(ReconcileDeposit::class)->report($deposit)->discrepancies);
    }

    private function transfer(string $providerReference = 'reconciliation-provider-reference'): ProviderTransfer
    {
        return new ProviderTransfer(
            organizationId: '00000000-0000-4000-8000-000000000001',
            installationIdentifier: 'reconciliation-installation',
            customerLookupIdentifier: Str::uuid()->toString(),
            providerReference: $providerReference,
            amountMinor: 12500,
            currency: 'CDF',
            providerOccurredAt: '2026-08-30T01:00:00+00:00',
            senderIdentifier: null,
            receiverIdentifier: null,
        );
    }
}
