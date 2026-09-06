<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\Filament\Pages\ManageOperatorSmsPatterns;
use App\Models\OperatorSmsPatternProposal;
use App\Models\Organization;
use App\Models\User;
use App\Security\FinancialOperatorMfaSession;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;
use Tests\TestCase;

final class FilamentOperatorSmsPatternsTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();
        Filament::setCurrentPanel(Filament::getPanel('operations'));
        config()->set('openpay.operator_sms_patterns.signing_secret', rtrim(strtr(base64_encode(str_repeat('s', 32)), '+/', '-_'), '='));
        $this->app->instance(FinancialOperatorMfaSession::class, new class implements FinancialOperatorMfaSession
        {
            public function assertVerified(User $user): void {}
        });
    }

    public function test_a_verified_developer_must_approve_before_creating_a_signed_mobile_release(): void
    {
        $operator = $this->financialOperator();
        $proposal = $this->proposal($operator, 'pending_review');
        $page = Livewire::actingAs($operator)
            ->test(ManageOperatorSmsPatterns::class)
            ->assertSee('Gemma proposals are review-only')
            ->assertDontSee('Paid 12.50 USD ref PRIVATE-REF');

        $page->callAction('approvePattern', data: ['proposal_id' => $proposal->id])
            ->assertHasNoFormErrors();
        self::assertSame('approved', $proposal->fresh()->status);
        self::assertDatabaseCount('operator_sms_pattern_releases', 0);

        $page->callAction('releasePattern', data: [
            'proposal_id' => $proposal->id,
            'expires_at' => now('UTC')->addDay()->format('Y-m-d H:i'),
        ])->assertHasNoFormErrors();
        self::assertDatabaseHas('operator_sms_pattern_releases', [
            'operator_sms_pattern_proposal_id' => $proposal->id,
            'organization_id' => $operator->organization_id,
            'provider' => 'ORANGE_MONEY',
            'sender' => 'ORANGE',
            'pattern_version' => 1,
        ]);
    }

    private function financialOperator(): User
    {
        return User::factory()->create([
            'organization_id' => Organization::query()->create()->getKey(),
            'is_financial_operator' => true,
        ]);
    }

    private function proposal(User $operator, string $status): OperatorSmsPatternProposal
    {
        return OperatorSmsPatternProposal::query()->create([
            'organization_id' => $operator->organization_id,
            'provider' => 'ORANGE_MONEY',
            'sender' => 'ORANGE',
            'template' => 'Paid {amount} {currency} ref {reference}',
            'template_sha256' => hash('sha256', 'orange-payment-pattern'),
            'model' => 'gemma-4-26b-a4b-it',
            'status' => $status,
        ]);
    }
}
