<?php

namespace Tests\Feature;

use App\Deposits\ProviderTransfer;
use App\Deposits\RecordProviderDeposit;
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
use Tests\TestCase;

final class ReconciliationTest extends TestCase
{
    use RefreshDatabase;

    public function test_an_operator_can_reconcile_a_reversal_without_rewriting_history(): void
    {
        $operator = User::factory()->create(['is_financial_operator' => true]);
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;

        $reversal = app(ReverseDeposit::class)->reverse($operator, $deposit, 'provider-correction');
        $report = app(ReconcileDeposit::class)->report($reversal->deposit);

        self::assertTrue($report->isReconciled);
        self::assertSame([], $report->discrepancies);
        self::assertDatabaseHas('deposits', [
            'id' => $reversal->deposit->id,
            'reverses_deposit_id' => $deposit->id,
            'reversal_reason' => 'provider-correction',
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
        $first = $repair->repair($operator, $deposit, 'missing-credit-posting');
        $replay = $repair->repair($operator, $deposit, 'missing-credit-posting');

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
        app(ReverseDeposit::class)->reverse($operator, $deposit, 'provider-correction');
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
        $reversal = app(ReverseDeposit::class)->reverse($operator, $deposit, 'provider-correction')->deposit;
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

    private function transfer(): ProviderTransfer
    {
        return new ProviderTransfer(
            organizationId: '00000000-0000-4000-8000-000000000001',
            installationIdentifier: 'reconciliation-installation',
            customerLookupIdentifier: Str::uuid()->toString(),
            providerReference: 'reconciliation-provider-reference',
            amountMinor: 12500,
            currency: 'CDF',
            providerOccurredAt: '2026-08-30T01:00:00+00:00',
            senderIdentifier: null,
            receiverIdentifier: null,
        );
    }
}
