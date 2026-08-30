<?php

namespace Tests\Feature;

use App\Models\InitialSetupState;
use App\Models\Organization;
use App\Models\User;
use App\Security\FinancialOperatorMfaSession;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Auth\Access\AuthorizationException;
use Laravel\Fortify\Events\ValidTwoFactorAuthenticationCodeProvided;
use Tests\TestCase;

final class InitialAdminSetupTest extends TestCase
{
    use RefreshDatabase;

    public function test_a_fresh_installation_exposes_the_one_time_administrator_setup_entry_point(): void
    {
        $this->get('/setup')->assertOk();
    }

    public function test_generic_registration_is_not_an_alternate_first_administrator_entry_point(): void
    {
        $this->get('/register')->assertNotFound();
    }

    public function test_password_sign_in_remains_available_as_the_passkey_fallback(): void
    {
        $this->get('/login')->assertOk();
    }

    public function test_initial_setup_creates_one_financial_operator_and_permanently_closes_setup(): void
    {
        $this->post('/setup', [
            'username' => 'initial-admin',
            'name' => 'Initial administrator',
            'email' => 'admin@example.test',
            'password' => 'correct-horse-battery-staple',
            'password_confirmation' => 'correct-horse-battery-staple',
        ])->assertRedirect('/setup/security');

        $this->assertDatabaseCount('organizations', 1);
        $this->assertDatabaseHas('users', [
            'username' => 'initial-admin',
            'email' => 'admin@example.test',
            'is_financial_operator' => true,
        ]);
        $this->assertNotNull(InitialSetupState::query()->findOrFail(1)->completed_at);

        $this->post('/setup', [
            'username' => 'second-admin',
            'name' => 'Second administrator',
            'email' => 'second@example.test',
            'password' => 'correct-horse-battery-staple',
            'password_confirmation' => 'correct-horse-battery-staple',
        ])->assertNotFound();

        $this->assertDatabaseCount('organizations', 1);
        $this->assertSame(1, User::query()->count());
        $this->assertSame(1, Organization::query()->count());
    }

    public function test_password_only_operator_session_cannot_access_financial_operations(): void
    {
        $operator = User::factory()->create([
            'is_financial_operator' => true,
            'two_factor_confirmed_at' => now(),
            'recovery_codes_confirmed_at' => now(),
        ]);

        $this->actingAs($operator);

        $this->expectException(AuthorizationException::class);

        app(FinancialOperatorMfaSession::class)->assertVerified($operator);
    }

    public function test_a_confirmed_totp_challenge_establishes_a_financial_operator_mfa_session(): void
    {
        $operator = User::factory()->create([
            'is_financial_operator' => true,
            'two_factor_confirmed_at' => now(),
            'recovery_codes_confirmed_at' => now(),
        ]);

        $this->actingAs($operator);
        event(new ValidTwoFactorAuthenticationCodeProvided($operator));

        app(FinancialOperatorMfaSession::class)->assertVerified($operator);
        $this->assertSame($operator->getAuthIdentifier(), session('financial_operator_mfa.user_id'));
    }
}
