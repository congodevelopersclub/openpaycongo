<?php

namespace Tests\Feature;

use App\Models\InitialSetupState;
use App\Models\Organization;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
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
}
