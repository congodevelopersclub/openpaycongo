<?php

namespace Tests\Feature;

use App\Deposits\ProviderTransfer;
use App\Deposits\RecordProviderDeposit;
use App\Filament\Pages\ReconcileDeposit;
use App\Models\User;
use App\Security\FinancialOperatorMfaSession;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use Livewire\Livewire;
use Tests\TestCase;

final class FilamentReconciliationTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        Filament::setCurrentPanel(Filament::getPanel('operations'));
    }

    public function test_an_operator_can_view_a_masked_reconciliation_report_in_filament(): void
    {
        $this->allowVerifiedMfaSessions();
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        $operator = User::factory()->create(['is_financial_operator' => true]);

        Livewire::actingAs($operator)
            ->test(ReconcileDeposit::class, ['deposit' => $deposit->id])
            ->assertSee('Reconciled')
            ->assertDontSee($deposit->provider_reference)
            ->assertDontSee($deposit->sender_identifier);
    }

    public function test_a_password_only_operator_cannot_access_the_page_or_actions(): void
    {
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        $operator = User::factory()->create(['is_financial_operator' => true]);

        Livewire::actingAs($operator)
            ->test(ReconcileDeposit::class, ['deposit' => $deposit->id])
            ->assertForbidden();
    }

    public function test_a_non_operator_cannot_access_a_reconciliation_report(): void
    {
        $this->allowVerifiedMfaSessions();
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        $user = User::factory()->create(['is_financial_operator' => false]);

        Livewire::actingAs($user)
            ->test(ReconcileDeposit::class, ['deposit' => $deposit->id])
            ->assertForbidden();
    }

    public function test_the_filament_repair_action_surfaces_the_discrepancy_and_records_an_audit(): void
    {
        $this->allowVerifiedMfaSessions();
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        DB::table('customer_credit_postings')->where('deposit_id', $deposit->id)->delete();
        DB::table('customer_credits')->where('customer_id', $deposit->customer_id)->where('currency', $deposit->currency)->update(['available_minor' => 0]);
        $operator = User::factory()->create(['is_financial_operator' => true]);

        Livewire::actingAs($operator)
            ->test(ReconcileDeposit::class, ['deposit' => $deposit->id])
            ->assertSee('customer_credit_posting')
            ->callAction('repairMissingCredit', data: ['reason_code' => 'missing_credit_posting'])
            ->assertHasNoFormErrors()
            ->assertSee('Reconciled');

        self::assertDatabaseHas('financial_correction_audits', [
            'deposit_id' => $deposit->id,
            'actor_user_id' => $operator->id,
            'correction' => 'repair_missing_customer_credit',
            'reason_code' => 'missing_credit_posting',
        ]);
    }

    public function test_the_filament_reversal_action_is_replay_safe_and_audited(): void
    {
        $this->allowVerifiedMfaSessions();
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        $operator = User::factory()->create(['is_financial_operator' => true]);
        $page = Livewire::actingAs($operator)->test(ReconcileDeposit::class, ['deposit' => $deposit->id]);

        $page->callAction('reverseDeposit', data: ['reason_code' => 'provider_correction'])->assertHasNoFormErrors();
        $page->callAction('reverseDeposit', data: ['reason_code' => 'provider_correction'])->assertHasNoFormErrors();

        self::assertDatabaseCount('financial_correction_audits', 1);
        self::assertDatabaseHas('financial_correction_audits', [
            'actor_user_id' => $operator->id,
            'correction' => 'reverse_deposit',
            'reason_code' => 'provider_correction',
        ]);
    }

    private function allowVerifiedMfaSessions(): void
    {
        $this->app->instance(FinancialOperatorMfaSession::class, new class implements FinancialOperatorMfaSession
        {
            public function assertVerified(User $user): void {}
        });
    }

    private function transfer(): ProviderTransfer
    {
        return new ProviderTransfer(
            organizationId: '00000000-0000-4000-8000-000000000001',
            installationIdentifier: 'filament-reconciliation-installation',
            customerLookupIdentifier: Str::uuid()->toString(),
            providerReference: 'filament-provider-reference',
            amountMinor: 12500,
            currency: 'CDF',
            providerOccurredAt: '2026-08-30T01:00:00+00:00',
            senderIdentifier: 'filament-sender-identifier',
            receiverIdentifier: null,
        );
    }
}
