<?php

namespace Tests\Feature;

use App\Models\SourceInstallation;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\RateLimiter;
use Laravel\Sanctum\Sanctum;
use Tests\TestCase;

final class IdentityBoundaryConfigurationTest extends TestCase
{
    use RefreshDatabase;

    public function test_identity_types_use_distinct_laravel_guards(): void
    {
        self::assertSame('session', config('auth.guards.web.driver'));
        self::assertSame('passport', config('auth.guards.services.driver'));
        self::assertSame('sanctum', config('auth.guards.mobile.driver'));
        self::assertSame('web', config('fortify.guard'));
    }

    public function test_mobile_ownership_is_resolved_from_the_authenticated_installation_not_request_input(): void
    {
        $installation = SourceInstallation::query()->create([
            'organization_id' => '00000000-0000-4000-8000-000000000009',
            'installation_digest' => str_repeat('a', 64),
        ]);

        Sanctum::actingAs($installation, ['mobile:sync:read'], 'mobile');

        $this->getJson('/mobile/identity?organization_id=00000000-0000-4000-8000-000000000010')
            ->assertOk()
            ->assertExactJson(['organization_id' => '00000000-0000-4000-8000-000000000009']);
    }

    public function test_web_session_and_wrong_mobile_ability_receive_same_non_enumerating_failure(): void
    {
        $web = User::factory()->create();
        $installation = SourceInstallation::query()->create([
            'organization_id' => '00000000-0000-4000-8000-000000000009',
            'installation_digest' => str_repeat('b', 64),
        ]);

        $this->actingAs($web)->getJson('/mobile/identity')->assertUnauthorized()->assertJson(['message' => 'Unauthenticated.']);
        Sanctum::actingAs($installation, ['mobile:sync:write'], 'mobile');
        $this->getJson('/mobile/identity')->assertForbidden()->assertJson(['message' => 'Forbidden']);
    }

    public function test_revoked_and_expired_mobile_tokens_fail_closed_without_secret_output(): void
    {
        app('auth')->forgetGuards();
        $installation = $this->installation();
        $revoked = $installation->createToken('mobile-installation', ['mobile:sync:read']);

        $this->withToken($revoked->plainTextToken)
            ->getJson('/mobile/identity')
            ->assertOk()
            ->assertDontSee($revoked->plainTextToken);

        $revoked->accessToken->delete();
        app('auth')->forgetGuards();

        $this->withToken($revoked->plainTextToken)
            ->getJson('/mobile/identity')
            ->assertUnauthorized()
            ->assertJson(['message' => 'Unauthenticated.'])
            ->assertDontSee($revoked->plainTextToken);

        config(['sanctum.expiration' => 1]);
        $expired = $installation->createToken('mobile-installation', ['mobile:sync:read']);
        $expired->accessToken->forceFill(['created_at' => now()->subMinutes(2)])->save();
        app('auth')->forgetGuards();

        $this->withToken($expired->plainTextToken)
            ->getJson('/mobile/identity')
            ->assertUnauthorized()
            ->assertJson(['message' => 'Unauthenticated.'])
            ->assertDontSee($expired->plainTextToken);
    }

    public function test_mobile_rate_limit_fails_closed_without_token_output(): void
    {
        app('auth')->forgetGuards();
        $installation = $this->installation();
        $token = $installation->createToken('mobile-installation', ['mobile:sync:read']);
        RateLimiter::clear((string) $installation->getAuthIdentifier());

        foreach (range(1, 60) as $attempt) {
            $this->withToken($token->plainTextToken)->getJson('/mobile/identity')->assertOk();
        }

        $this->withToken($token->plainTextToken)
            ->getJson('/mobile/identity')
            ->assertStatus(429)
            ->assertDontSee($token->plainTextToken);
    }

    private function installation(): SourceInstallation
    {
        return SourceInstallation::query()->create([
            'organization_id' => '00000000-0000-4000-8000-000000000009',
            'installation_digest' => str_repeat('c', 64),
        ]);
    }
}
