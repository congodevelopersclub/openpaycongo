<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\Filament\Pages\IssuePairingIntent;
use App\Models\Organization;
use App\Models\PairingIntent;
use App\Models\User;
use App\Security\FinancialOperatorMfaSession;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;
use Tests\TestCase;

final class FilamentPairingIntentTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        config(['openpay.pairing' => [
            'endpoint' => 'https://pairing.openpay.example/v1/pairing/complete',
            'enrollment_signing_secret' => rtrim(strtr(base64_encode(str_repeat('s', 32)), '+/', '-_'), '='),
            'trust_mode' => 'first_use_requires_sas',
        ]]);
        Filament::setCurrentPanel(Filament::getPanel('operations'));
        $this->app->instance(FinancialOperatorMfaSession::class, new class implements FinancialOperatorMfaSession
        {
            public function assertVerified(User $user): void {}
        });
    }

    public function test_a_verified_operator_can_issue_a_short_lived_public_qr_without_protected_material(): void
    {
        $operator = $this->financialOperator();

        $page = Livewire::actingAs($operator)
            ->test(IssuePairingIntent::class)
            ->callAction('issuePairingIntent', data: ['lifetime_seconds' => 60])
            ->assertHasNoFormErrors()
            ->assertSee('Scan this QR code with the OpenPay Congo mobile app.')
            ->assertDontSee('protected_server_private_material');

        $intent = PairingIntent::query()->sole();
        self::assertSame($operator->organization_id, $intent->organization_id);
        self::assertNotSame('', $intent->protected_server_private_material);
        $page->assertDontSee($intent->protected_server_private_material)
            ->assertDontSee((string) config('openpay.pairing.enrollment_signing_secret'));
    }

    public function test_the_pairing_action_rejects_lifetimes_outside_the_short_lived_window(): void
    {
        Livewire::actingAs($this->financialOperator())
            ->test(IssuePairingIntent::class)
            ->callAction('issuePairingIntent', data: ['lifetime_seconds' => 301])
            ->assertHasFormErrors(['lifetime_seconds']);

        self::assertDatabaseCount('pairing_intents', 0);
    }

    public function test_the_pairing_action_applies_the_same_five_per_minute_issuance_limit_as_the_operator_api(): void
    {
        $operator = $this->financialOperator();
        $page = Livewire::actingAs($operator)->test(IssuePairingIntent::class);

        for ($attempt = 0; $attempt < 5; $attempt++) {
            $page->callAction('issuePairingIntent', data: ['lifetime_seconds' => 60])
                ->assertHasNoFormErrors();
        }

        $page->callAction('issuePairingIntent', data: ['lifetime_seconds' => 60]);

        self::assertDatabaseCount('pairing_intents', 5);
    }

    public function test_the_page_and_livewire_updates_that_can_carry_a_qr_are_never_cacheable(): void
    {
        $operator = $this->financialOperator();

        $initial = $this->actingAs($operator)
            ->withSession(['financial_operator_mfa.user_id' => $operator->getAuthIdentifier()])
            ->get('/operations/issue-pairing-intent')
            ->assertOk()
            ->assertHeader('Cache-Control', 'no-store, private');

        preg_match('/wire:snapshot="([^"]+)"/', $initial->getContent(), $snapshot);

        self::assertArrayHasKey(1, $snapshot);

        $updatePath = parse_url(route('default-livewire.update'), PHP_URL_PATH);

        self::assertIsString($updatePath);

        $this->withHeader('X-Livewire', 'true')->postJson($updatePath, [
            'components' => [[
                'snapshot' => html_entity_decode($snapshot[1], ENT_QUOTES | ENT_HTML5),
                'updates' => [],
                'calls' => [],
            ]],
        ])
            ->assertOk()
            ->assertHeader('Cache-Control', 'no-store, private');
    }

    public function test_a_password_only_operator_cannot_mount_or_issue_a_pairing_intent(): void
    {
        $this->app->instance(FinancialOperatorMfaSession::class, new class implements FinancialOperatorMfaSession
        {
            public function assertVerified(User $user): void
            {
                abort(403);
            }
        });

        Livewire::actingAs($this->financialOperator())
            ->test(IssuePairingIntent::class)
            ->assertForbidden();

        self::assertDatabaseCount('pairing_intents', 0);
    }

    private function financialOperator(): User
    {
        return User::factory()->create([
            'organization_id' => Organization::query()->create()->getKey(),
            'is_financial_operator' => true,
            'two_factor_confirmed_at' => now(),
            'recovery_codes_confirmed_at' => now(),
        ]);
    }
}
