<?php

namespace Tests\Feature;

use App\Deposits\ProviderTransfer;
use App\Deposits\RecordProviderDeposit;
use App\Filament\Pages\ReconcileDeposit;
use App\Models\Deposit;
use App\Models\User;
use App\Policies\DepositPolicy;
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
        $operator = $this->userFor($deposit, true);

        Livewire::actingAs($operator)
            ->test(ReconcileDeposit::class, ['deposit' => $deposit->id])
            ->assertSee('Reconciled')
            ->assertDontSee($deposit->provider_reference)
            ->assertDontSee($deposit->sender_identifier);
    }

    public function test_a_password_only_operator_cannot_access_the_page_or_actions(): void
    {
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        $operator = $this->userFor($deposit, true);

        Livewire::actingAs($operator)
            ->test(ReconcileDeposit::class, ['deposit' => $deposit->id])
            ->assertForbidden();
    }

    public function test_a_non_operator_cannot_access_a_reconciliation_report(): void
    {
        $this->allowVerifiedMfaSessions();
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        $user = $this->userFor($deposit, false);

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
        $operator = $this->userFor($deposit, true);

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
        $operator = $this->userFor($deposit, true);
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

    public function test_financial_operator_authorization_is_limited_to_their_organization(): void
    {
        $policy = new DepositPolicy;
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        $otherDeposit = app(RecordProviderDeposit::class)->record($this->transfer('00000000-0000-4000-8000-000000000002'))->deposit;
        $operator = $this->userFor($deposit, true);

        self::assertTrue($policy->viewAny($operator));
        self::assertTrue($policy->view($operator, $deposit));
        self::assertTrue($policy->correct($operator, $deposit));
        self::assertFalse($policy->view($operator, $otherDeposit));
        self::assertFalse($policy->correct($operator, $otherDeposit));
    }

    public function test_a_financial_operator_without_an_organization_cannot_access_deposits(): void
    {
        $policy = new DepositPolicy;
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        $operator = User::factory()->create(['is_financial_operator' => true]);

        self::assertFalse($policy->viewAny($operator));
        self::assertFalse($policy->view($operator, $deposit));
        self::assertFalse($policy->correct($operator, $deposit));
    }

    private function userFor(Deposit $deposit, bool $isFinancialOperator): User
    {
        $user = User::factory()->create(['is_financial_operator' => $isFinancialOperator]);
        $user->forceFill(['organization_id' => $deposit->organization_id])->save();

        return $user;
    }

    private function allowVerifiedMfaSessions(): void
    {
        $this->app->instance(FinancialOperatorMfaSession::class, new class implements FinancialOperatorMfaSession
        {
            public function assertVerified(User $user): void {}
        });
    }

    private function transfer(string $organizationId = '00000000-0000-4000-8000-000000000001'): ProviderTransfer
    {
        return new ProviderTransfer(
            organizationId: $organizationId,
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
