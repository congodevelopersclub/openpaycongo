<?php

namespace Tests\Feature;

use App\Deposits\ProviderTransfer;
use App\Deposits\RecordProviderDeposit;
use App\Models\Customer;
use App\Models\CustomerCredit;
use App\Models\CustomerCreditPosting;
use App\Models\Deposit;
use App\Models\FinancialCorrectionAudit;
use App\Models\LedgerEntry;
use App\Models\User;
use App\Reconciliation\ReconcileDeposit;
use App\Reconciliation\RepairMissingCustomerCredit;
use App\Reconciliation\ReverseDeposit;
use App\Security\FinancialOperatorMfaSession;
use App\Security\UnavailableFinancialOperatorMfaSession;
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

    protected function setUp(): void
    {
        parent::setUp();
        $this->app->instance(FinancialOperatorMfaSession::class, new class implements FinancialOperatorMfaSession
        {
            public function assertVerified(User $user): void {}
        });
    }

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

    public function test_repair_replay_requires_matching_intent_and_evidence(): void
    {
        $operator = User::factory()->create(['is_financial_operator' => true]);
        $otherOperator = User::factory()->create(['is_financial_operator' => true]);
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer('repair-replay'))->deposit;
        CustomerCreditPosting::query()->where('deposit_id', $deposit->id)->delete();
        CustomerCredit::query()->where('customer_id', $deposit->customer_id)->where('currency', $deposit->currency)->update(['available_minor' => 0]);
        $repair = app(RepairMissingCustomerCredit::class);

        self::assertTrue($repair->repair($operator, $deposit, 'missing_credit_posting', 'confirmed')->repaired);
        self::assertFalse($repair->repair($operator, $deposit, 'missing_credit_posting', 'confirmed')->repaired);

        foreach ([[$otherOperator, 'missing_credit_posting', 'confirmed'], [$operator, 'other_reason', 'confirmed'], [$operator, 'missing_credit_posting', 'changed']] as [$actor, $reason, $detail]) {
            try {
                $repair->repair($actor, $deposit, $reason, $detail);
                self::fail('A changed repair replay intent must be rejected.');
            } catch (ValidationException) {
                self::assertDatabaseCount('financial_correction_audits', 1);
            }
        }
    }

    public function test_repair_rejects_a_normal_existing_posting_without_correction_evidence(): void
    {
        $operator = User::factory()->create(['is_financial_operator' => true]);
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer('normal-posting'))->deposit;
        $credit = CustomerCredit::query()->where('customer_id', $deposit->customer_id)->where('currency', $deposit->currency)->firstOrFail();

        $this->expectException(ValidationException::class);
        try {
            app(RepairMissingCustomerCredit::class)->repair($operator, $deposit, 'missing_credit_posting');
        } finally {
            self::assertDatabaseCount('customer_credit_postings', 1);
            self::assertSame((int) $deposit->amount_minor, (int) $credit->fresh()->available_minor);
            self::assertDatabaseCount('financial_correction_audits', 0);
        }
    }

    public function test_repair_replay_rejects_missing_evidence_or_an_unreconciled_state_without_mutation(): void
    {
        $operator = User::factory()->create(['is_financial_operator' => true]);
        $repair = app(RepairMissingCustomerCredit::class);

        $withoutAudit = app(RecordProviderDeposit::class)->record($this->transfer('repair-audit-deleted'))->deposit;
        CustomerCreditPosting::query()->where('deposit_id', $withoutAudit->id)->delete();
        CustomerCredit::query()->where('customer_id', $withoutAudit->customer_id)->where('currency', $withoutAudit->currency)->update(['available_minor' => 0]);
        $repair->repair($operator, $withoutAudit, 'missing_credit_posting', 'confirmed');
        FinancialCorrectionAudit::query()->where('deposit_id', $withoutAudit->id)->delete();

        try {
            $repair->repair($operator, $withoutAudit, 'missing_credit_posting', 'confirmed');
            self::fail('A replay missing its correction evidence must be rejected.');
        } catch (ValidationException) {
            self::assertDatabaseCount('customer_credit_postings', 1);
            self::assertDatabaseCount('financial_correction_audits', 0);
            self::assertSame((int) $withoutAudit->amount_minor, (int) CustomerCredit::query()->where('customer_id', $withoutAudit->customer_id)->value('available_minor'));
        }

        $unreconciled = app(RecordProviderDeposit::class)->record($this->transfer('repair-state-drift'))->deposit;
        CustomerCreditPosting::query()->where('deposit_id', $unreconciled->id)->delete();
        CustomerCredit::query()->where('customer_id', $unreconciled->customer_id)->where('currency', $unreconciled->currency)->update(['available_minor' => 0]);
        $repair->repair($operator, $unreconciled, 'missing_credit_posting', 'confirmed');
        CustomerCredit::query()->where('customer_id', $unreconciled->customer_id)->where('currency', $unreconciled->currency)->update(['available_minor' => 1]);

        try {
            $repair->repair($operator, $unreconciled, 'missing_credit_posting', 'confirmed');
            self::fail('An unreconciled repair replay must be rejected.');
        } catch (ValidationException) {
            self::assertDatabaseCount('customer_credit_postings', 2);
            self::assertDatabaseCount('financial_correction_audits', 1);
            self::assertSame(1, (int) CustomerCredit::query()->where('customer_id', $unreconciled->customer_id)->value('available_minor'));
        }
    }

    public function test_a_non_operator_cannot_reverse_or_repair_financial_records(): void
    {
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        $operator = User::factory()->create(['is_financial_operator' => false]);

        $this->expectException(AuthorizationException::class);
        app(ReverseDeposit::class)->reverse($operator, $deposit, 'provider_correction');
    }

    public function test_a_password_only_operator_cannot_invoke_correction_actions_directly(): void
    {
        $this->app->instance(FinancialOperatorMfaSession::class, new UnavailableFinancialOperatorMfaSession);
        $operator = User::factory()->create(['is_financial_operator' => true]);
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer('password-only-action'))->deposit;
        $credit = CustomerCredit::query()->where('customer_id', $deposit->customer_id)->where('currency', $deposit->currency)->firstOrFail();

        foreach ([
            fn () => app(ReverseDeposit::class)->reverse($operator, $deposit, 'provider_correction'),
            fn () => app(RepairMissingCustomerCredit::class)->repair($operator, $deposit, 'missing_credit_posting'),
        ] as $action) {
            try {
                $action();
                self::fail('A password-only operator must not invoke correction Actions directly.');
            } catch (AuthorizationException) {
                self::assertDatabaseCount('financial_correction_audits', 0);
                self::assertDatabaseCount('customer_credit_postings', 1);
                self::assertSame((int) $deposit->amount_minor, (int) $credit->fresh()->available_minor);
            }
        }
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

    public function test_reconciliation_rejects_same_sided_original_ledger_links_and_missing_audit_evidence(): void
    {
        $operator = User::factory()->create(['is_financial_operator' => true]);
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        $reversal = app(ReverseDeposit::class)->reverse($operator, $deposit, 'provider_correction')->deposit;

        DB::table('ledger_entries')->where('deposit_id', $reversal->id)->where('account', 'customer_credit')->update(['debit_minor' => 0, 'credit_minor' => 12500]);
        DB::table('ledger_entries')->where('deposit_id', $reversal->id)->where('account', 'provider_receivable')->update(['debit_minor' => 12500, 'credit_minor' => 0]);
        DB::table('financial_correction_audits')->where('deposit_id', $reversal->id)->delete();

        $discrepancies = app(ReconcileDeposit::class)->report($reversal)->discrepancies;

        self::assertContains('reversal_ledger_linkage', $discrepancies);
        self::assertContains('reversal_evidence', $discrepancies);
    }

    public function test_reversal_refuses_a_customer_credit_balance_drift(): void
    {
        $operator = User::factory()->create(['is_financial_operator' => true]);
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        CustomerCredit::query()->where('customer_id', $deposit->customer_id)->where('currency', $deposit->currency)->update(['available_minor' => 1]);

        $this->expectException(ValidationException::class);
        app(ReverseDeposit::class)->reverse($operator, $deposit, 'provider_correction');
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

    public function test_reversal_replay_requires_the_exact_original_intent_and_clean_evidence(): void
    {
        $operator = User::factory()->create(['is_financial_operator' => true]);
        $otherOperator = User::factory()->create(['is_financial_operator' => true]);
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer('exact-replay'))->deposit;
        $action = app(ReverseDeposit::class);
        $first = $action->reverse($operator, $deposit, 'provider_correction', 'operator-confirmed');

        self::assertSame('reversed', $first->outcome->value);
        self::assertSame('replayed', $action->reverse($operator, $deposit, 'provider_correction', 'operator-confirmed')->outcome->value);

        foreach ([[$otherOperator, 'provider_correction', 'operator-confirmed'], [$operator, 'other_reason', 'operator-confirmed'], [$operator, 'provider_correction', 'changed-detail']] as [$actor, $reason, $detail]) {
            try {
                $action->reverse($actor, $deposit, $reason, $detail);
                self::fail('A changed reversal replay intent must be rejected.');
            } catch (ValidationException) {
                self::assertDatabaseCount('financial_correction_audits', 1);
            }
        }

        DB::table('ledger_entries')->where('deposit_id', $first->deposit->id)->where('account', 'customer_credit')->update(['debit_minor' => 1]);

        $this->expectException(ValidationException::class);
        $action->reverse($operator, $deposit, 'provider_correction', 'operator-confirmed');
    }

    public function test_reconciliation_evidence_migration_refuses_to_rollback_provisioned_operator_authorization(): void
    {
        User::factory()->create(['is_financial_operator' => true]);
        $migration = require base_path('database/migrations/2026_09_02_000000_add_reconciliation_correction_evidence.php');

        $this->expectException(\LogicException::class);
        $migration->down();
    }

    public function test_reconciliation_rejects_an_unknown_deposit_kind(): void
    {
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        DB::table('deposits')->where('id', $deposit->id)->update(['kind' => 'unknown']);

        self::assertContains('unsupported_deposit_kind', app(ReconcileDeposit::class)->report($deposit)->discrepancies);
    }

    public function test_reconciliation_rejects_a_customer_outside_the_deposit_organization(): void
    {
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        DB::table('customers')->where('id', $deposit->customer_id)->update(['organization_id' => '00000000-0000-4000-8000-000000000099']);

        self::assertContains('customer_scope_mismatch', app(ReconcileDeposit::class)->report($deposit)->discrepancies);
    }

    public function test_reconciliation_requires_a_provider_credit_as_the_reversal_original(): void
    {
        $operator = User::factory()->create(['is_financial_operator' => true]);
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        $reversal = app(ReverseDeposit::class)->reverse($operator, $deposit, 'provider_correction')->deposit;
        DB::table('deposits')->where('id', $deposit->id)->update(['kind' => 'provider_reversal']);

        self::assertContains('reversal_evidence', app(ReconcileDeposit::class)->report($reversal)->discrepancies);
    }

    public function test_reconciliation_rejects_the_exact_malformed_evidence_states_without_a_correction(): void
    {
        $operator = User::factory()->create(['is_financial_operator' => true]);
        $reverse = app(ReverseDeposit::class);
        $reconcile = app(ReconcileDeposit::class);

        $misScoped = app(RecordProviderDeposit::class)->record($this->transfer('mis-scoped-original'))->deposit;
        $otherCustomer = Customer::query()->create([
            'organization_id' => $misScoped->organization_id,
            'private_lookup_digest' => hash('sha256', 'mis-scoped-customer'),
            'private_lookup_id' => 'mis-scoped-customer',
            'private_lookup_key_version' => 'test',
        ]);
        $otherCredit = CustomerCredit::query()->create(['customer_id' => $otherCustomer->id, 'currency' => $misScoped->currency, 'available_minor' => $misScoped->amount_minor]);
        CustomerCreditPosting::query()->where('deposit_id', $misScoped->id)->update(['customer_credit_id' => $otherCredit->id]);
        CustomerCredit::query()->where('customer_id', $misScoped->customer_id)->where('currency', $misScoped->currency)->update(['available_minor' => 0]);

        self::assertContains('customer_credit_posting_scope', $reconcile->report($misScoped)->discrepancies);
        $this->assertCorrectionIsRejected($reverse, $operator, $misScoped);

        $unsupported = app(RecordProviderDeposit::class)->record($this->transfer('unsupported-kind'))->deposit;
        DB::table('deposits')->where('id', $unsupported->id)->update(['kind' => 'unknown']);

        self::assertFalse($reconcile->report($unsupported)->isReconciled);
        self::assertContains('unsupported_deposit_kind', $reconcile->report($unsupported)->discrepancies);
        $this->assertCorrectionIsRejected($reverse, $operator, $unsupported);

        $withoutAudit = app(RecordProviderDeposit::class)->record($this->transfer('missing-reversal-audit'))->deposit;
        $reversal = $reverse->reverse($operator, $withoutAudit, 'provider_correction')->deposit;
        FinancialCorrectionAudit::query()->where('deposit_id', $reversal->id)->delete();

        self::assertContains('reversal_evidence', $reconcile->report($reversal)->discrepancies);
        $this->assertCorrectionIsRejected($reverse, $operator, $withoutAudit);

        $wrongOrganization = app(RecordProviderDeposit::class)->record($this->transfer('customer-organization-mismatch'))->deposit;
        DB::table('customers')->where('id', $wrongOrganization->customer_id)->update(['organization_id' => '00000000-0000-4000-8000-000000000099']);

        self::assertContains('customer_scope_mismatch', $reconcile->report($wrongOrganization)->discrepancies);
        $this->assertCorrectionIsRejected($reverse, $operator, $wrongOrganization);

        $wrongOriginalKind = app(RecordProviderDeposit::class)->record($this->transfer('wrong-original-kind'))->deposit;
        $wrongOriginalReversal = $reverse->reverse($operator, $wrongOriginalKind, 'provider_correction')->deposit;
        DB::table('deposits')->where('id', $wrongOriginalKind->id)->update(['kind' => 'unknown']);

        self::assertContains('reversal_evidence', $reconcile->report($wrongOriginalReversal)->discrepancies);
    }

    private function assertCorrectionIsRejected(ReverseDeposit $reverse, User $operator, Deposit $deposit): void
    {
        $depositCount = Deposit::query()->count();
        $postingCount = CustomerCreditPosting::query()->count();
        $auditCount = FinancialCorrectionAudit::query()->count();

        try {
            $reverse->reverse($operator, $deposit, 'provider_correction');
            self::fail('A correction against malformed evidence must be rejected.');
        } catch (ValidationException) {
            self::assertSame($depositCount, Deposit::query()->count());
            self::assertSame($postingCount, CustomerCreditPosting::query()->count());
            self::assertSame($auditCount, FinancialCorrectionAudit::query()->count());
        }
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
