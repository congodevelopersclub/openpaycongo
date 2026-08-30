<?php

namespace Tests\Feature;

use App\Models\DeveloperApplication;
use App\Models\SourceInstallation;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\RateLimiter;
use Laravel\Passport\Client;
use Laravel\Passport\ClientRepository;
use Laravel\Sanctum\Sanctum;
use Tests\TestCase;

final class IdentityBoundaryConfigurationTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        Artisan::call('passport:keys', ['--force' => true]);
    }

    public function test_identity_types_use_distinct_laravel_guards(): void
    {
        self::assertSame('session', config('auth.guards.web.driver'));
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

    public function test_service_identity_uses_only_validated_client_persisted_ownership(): void
    {
        [$application, $client] = $this->developerApplication('00000000-0000-4000-8000-000000000011');
        $accessToken = $this->serviceAccessToken($client, ['payment-requests:read']);

        $this->withToken($accessToken)
            ->getJson('/services/identity?organization_id=00000000-0000-4000-8000-000000000012&application_id=00000000-0000-4000-8000-000000000013')
            ->assertOk()
            ->assertExactJson([
                'application_id' => $application->getKey(),
                'organization_id' => $application->organization_id,
            ])
            ->assertDontSee($client->plainSecret);
    }

    public function test_mobile_wrong_scope_and_revoked_service_client_fail_closed_without_secret_output(): void
    {
        [$application, $client] = $this->developerApplication('00000000-0000-4000-8000-000000000011');
        $mobile = $this->installation();
        $mobileToken = $mobile->createToken('mobile-installation', ['mobile:sync:read']);
        app('auth')->forgetGuards();

        $this->withToken($mobileToken->plainTextToken)
            ->getJson('/services/identity')
            ->assertUnauthorized()
            ->assertJson(['message' => 'Unauthenticated.'])
            ->assertDontSee($mobileToken->plainTextToken);

        $wrongScopeToken = $this->serviceAccessToken($client, ['wallets:read']);
        $this->withToken($wrongScopeToken)
            ->getJson('/services/identity')
            ->assertForbidden()
            ->assertJson(['message' => 'Forbidden'])
            ->assertDontSee($client->plainSecret);

        $validToken = $this->serviceAccessToken($client, ['payment-requests:read']);
        $client->forceFill(['revoked' => true])->save();
        app('auth')->forgetGuards();

        $this->withToken($validToken)
            ->getJson('/services/identity')
            ->assertUnauthorized()
            ->assertJson(['message' => 'Unauthenticated.'])
            ->assertDontSee($client->plainSecret);
    }

    private function installation(): SourceInstallation
    {
        return SourceInstallation::query()->create([
            'organization_id' => '00000000-0000-4000-8000-000000000009',
            'installation_digest' => str_repeat('c', 64),
        ]);
    }

    /** @return array{DeveloperApplication, Client} */
    private function developerApplication(string $organizationId): array
    {
        $client = app(ClientRepository::class)->createClientCredentialsGrantClient('synthetic-service');
        $application = DeveloperApplication::query()->create([
            'organization_id' => $organizationId,
            'oauth_client_id' => $client->getKey(),
        ]);

        return [$application, $client];
    }

    /** @param string[] $scopes */
    private function serviceAccessToken(Client $client, array $scopes): string
    {
        $response = $this->postJson('/oauth/token', [
            'grant_type' => 'client_credentials',
            'client_id' => $client->getKey(),
            'client_secret' => $client->plainSecret,
            'scope' => implode(' ', $scopes),
        ])->assertOk()->assertJsonMissing(['client_secret']);

        return (string) $response->json('access_token');
    }
}
