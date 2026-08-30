<?php

namespace Tests\Feature;

use App\Models\InitialSetupState;
use App\Models\Organization;
use App\Models\SecurityAudit;
use App\Models\User;
use App\Security\FinancialOperatorMfaSession;
use Illuminate\Auth\Access\AuthorizationException;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Crypt;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;
use Laravel\Fortify\Events\RecoveryCodesGenerated;
use Laravel\Fortify\Events\ValidTwoFactorAuthenticationCodeProvided;
use Tests\TestCase;

final class InitialAdminSetupTest extends TestCase
{
    use RefreshDatabase;

    public function test_a_fresh_installation_exposes_the_one_time_administrator_setup_entry_point(): void
    {
        $this->get('/setup')->assertOk();
    }

    public function test_a_legacy_installation_with_users_never_reopens_public_setup(): void
    {
        User::factory()->create();
        Schema::drop('initial_setup_states');

        $migration = require database_path('migrations/2026_09_03_000000_create_initial_setup_states_table.php');
        $migration->up();

        $this->assertNotNull(InitialSetupState::query()->findOrFail(1)->completed_at);
        $this->get('/setup')->assertNotFound();
        $this->post('/setup')->assertNotFound();
        $this->assertSame(1, User::query()->count());
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

    public function test_completed_setup_rejects_malformed_replays_before_validation(): void
    {
        $this->post('/setup', [
            'username' => 'initial-admin',
            'name' => 'Initial administrator',
            'email' => 'admin@example.test',
            'password' => 'correct-horse-battery-staple',
            'password_confirmation' => 'correct-horse-battery-staple',
        ])->assertRedirect('/setup/security');

        $this->post('/setup')->assertNotFound();

        $this->assertDatabaseCount('organizations', 1);
        $this->assertSame(1, User::query()->count());
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

    public function test_a_confirmed_operator_must_acknowledge_recovery_codes_before_mfa_can_be_established(): void
    {
        $operator = User::factory()->create([
            'is_financial_operator' => true,
            'two_factor_confirmed_at' => now(),
            'two_factor_recovery_codes' => Crypt::encryptString('[]'),
        ]);

        $this->actingAs($operator)
            ->post('/setup/security/recovery-codes/acknowledge', ['recovery_codes_saved' => true])
            ->assertRedirect('/setup/security');

        $this->assertNotNull($operator->fresh()->recovery_codes_confirmed_at);
    }

    public function test_setup_security_requires_authentication(): void
    {
        $this->get('/setup/security')->assertRedirect('/login');
    }

    public function test_the_passkey_boundary_uses_the_explicit_local_trust_contract(): void
    {
        $this->assertSame('localhost', config('fortify.passkeys.relying_party_id'));
        $this->assertSame(['https://localhost'], config('fortify.passkeys.allowed_origins'));
        $this->assertTrue(in_array('passkeys', config('fortify.features'), true));
    }

    public function test_a_signed_in_operator_can_access_real_passkey_registration_controls(): void
    {
        $operator = User::factory()->create([
            'is_financial_operator' => true,
            'two_factor_confirmed_at' => now(),
        ]);

        $this->actingAs($operator)
            ->get('/setup/security')
            ->assertOk()
            ->assertSee('data-passkey-registration', false)
            ->assertSee('data-passkey-name', false);
    }

    public function test_password_fallback_sends_a_totp_enabled_operator_to_the_fortify_challenge(): void
    {
        $operator = User::factory()->create([
            'email' => 'operator@example.test',
            'password' => 'correct-horse-battery-staple',
            'two_factor_secret' => Crypt::encryptString('test-only-totp-secret'),
            'two_factor_confirmed_at' => now(),
        ]);

        $this->post('/login', [
            'email' => $operator->email,
            'password' => 'correct-horse-battery-staple',
        ])->assertRedirect('/two-factor-challenge');
    }

    public function test_passkey_registration_requires_fresh_password_confirmation(): void
    {
        $operator = User::factory()->create();

        $this->actingAs($operator)
            ->get('/user/passkeys/options')
            ->assertRedirect('/user/confirm-password');
    }

    public function test_an_operator_cannot_remove_another_users_passkey(): void
    {
        $operator = User::factory()->create();
        $otherUser = User::factory()->create();
        $passkey = $otherUser->passkeys()->create([
            'name' => 'Other device',
            'credential_id' => (string) Str::uuid(),
            'credential' => [],
        ]);

        $this->actingAs($operator)
            ->withSession(['auth.password_confirmed_at' => time()])
            ->delete(route('passkey.destroy', $passkey))
            ->assertForbidden();

        $this->assertDatabaseHas('passkeys', ['id' => $passkey->getKey(), 'user_id' => $otherUser->getKey()]);
    }

    public function test_the_passkey_trust_configuration_never_uses_request_host_headers(): void
    {
        $configuration = file_get_contents(config_path('fortify.php'));

        $this->assertIsString($configuration);
        $this->assertStringContainsString('OPENPAY_PASSKEY_RP_ID', $configuration);
        $this->assertStringContainsString('OPENPAY_PASSKEY_ALLOWED_ORIGINS', $configuration);
        $this->assertStringNotContainsString('HTTP_HOST', $configuration);
        $this->assertStringNotContainsString('X_FORWARDED_HOST', $configuration);
    }

    public function test_recovery_code_regeneration_invalidates_acknowledgement_without_auditing_secrets(): void
    {
        $operator = User::factory()->create([
            'two_factor_confirmed_at' => now(),
            'two_factor_recovery_codes' => Crypt::encryptString('[]'),
            'recovery_codes_confirmed_at' => now(),
        ]);

        event(new RecoveryCodesGenerated($operator));

        $this->assertNull($operator->fresh()->recovery_codes_confirmed_at);
        $this->assertDatabaseHas('security_audits', [
            'user_id' => $operator->getKey(),
            'action' => 'recovery_codes_generated',
        ]);
        $this->assertSame(['id', 'user_id', 'action', 'created_at'], array_keys(SecurityAudit::query()->firstOrFail()->getAttributes()));
    }
}
