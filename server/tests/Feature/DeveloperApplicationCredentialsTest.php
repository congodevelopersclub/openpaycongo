<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\DeveloperApplications\ManageDeveloperApplicationCredentials;
use App\Filament\Pages\ManageDeveloperApplications;
use App\Models\DeveloperApplication;
use App\Models\DeveloperApplicationCredentialAudit;
use App\Models\Organization;
use App\Models\User;
use App\Security\FinancialOperatorMfaSession;
use Carbon\CarbonImmutable;
use Filament\Facades\Filament;
use Illuminate\Auth\Access\AuthorizationException;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Artisan;
use Laravel\Passport\Client;
use Laravel\Passport\ClientRepository;
use Laravel\Passport\Passport;
use Livewire\Livewire;
use ReflectionClass;
use ReflectionMethod;
use Tests\TestCase;

final class DeveloperApplicationCredentialsTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        Artisan::call('passport:keys', ['--force' => true]);
        Filament::setCurrentPanel(Filament::getPanel('operations'));
        $this->app->instance(FinancialOperatorMfaSession::class, new class implements FinancialOperatorMfaSession
        {
            public function assertVerified(User $user): void {}
        });
    }

    public function test_operator_issues_one_time_client_credentials_for_one_application_scope_set(): void
    {
        $operator = $this->financialOperator('00000000-0000-4000-8000-000000000201');

        $issued = app(ManageDeveloperApplicationCredentials::class)->issue(
            $operator,
            'Checkout connector',
            ['payment-requests:read'],
        );

        $application = DeveloperApplication::query()->sole();
        $client = $application->oauthClient()->firstOrFail();

        self::assertSame($application->getKey(), $issued->application->getKey());
        self::assertSame($client->getKey(), $issued->clientId);
        self::assertNotSame('', $issued->clientSecret);
        self::assertNotSame($issued->clientSecret, $client->secret);
        self::assertSame($operator->organization_id, $application->organization_id);
        self::assertSame('Checkout connector', $application->name);
        self::assertSame('Checkout connector', $client->name);
        self::assertSame(['payment-requests:read'], $client->scopes);

        $token = $this->tokenFor($client, $issued->clientSecret, 'payment-requests:read');

        $this->withToken($token)
            ->getJson('/services/identity')
            ->assertOk()
            ->assertExactJson([
                'application_id' => $application->getKey(),
                'organization_id' => $operator->organization_id,
            ])
            ->assertDontSee($issued->clientSecret);

        self::assertNotNull($client->refresh()->last_used_at);

        $this->postJson('/oauth/token', [
            'grant_type' => 'client_credentials',
            'client_id' => $client->getKey(),
            'client_secret' => $issued->clientSecret,
            'scope' => 'customers:pii:read',
        ])->assertStatus(400)
            ->assertJsonPath('error', 'invalid_scope')
            ->assertDontSee($issued->clientSecret);

        $audit = DeveloperApplicationCredentialAudit::query()->sole();
        self::assertSame('issued', $audit->action);
        self::assertSame($operator->getKey(), $audit->actor_user_id);
        self::assertSame($operator->organization_id, $audit->organization_id);
        self::assertSame($application->getKey(), $audit->developer_application_id);
        self::assertSame($client->getKey(), $audit->oauth_client_id);
        self::assertSame(['payment-requests:read'], $audit->scopes);
        self::assertArrayNotHasKey('client_secret', $audit->getAttributes());
    }

    public function test_rotation_revokes_old_credentials_and_preserves_scope_isolation(): void
    {
        $operator = $this->financialOperator('00000000-0000-4000-8000-000000000202');
        $issued = app(ManageDeveloperApplicationCredentials::class)->issue($operator, 'Ledger connector', ['payment-requests:read']);
        $application = $issued->application;
        $oldClient = $application->oauthClient()->firstOrFail();
        $oldToken = $this->tokenFor($oldClient, $issued->clientSecret, 'payment-requests:read');

        $rotated = app(ManageDeveloperApplicationCredentials::class)->rotate($operator, $application);

        $application->refresh();
        $newClient = $application->oauthClient()->firstOrFail();

        self::assertNotSame($oldClient->getKey(), $newClient->getKey());
        self::assertSame($newClient->getKey(), $rotated->clientId);
        self::assertTrue((bool) $oldClient->refresh()->revoked);
        self::assertSame('Ledger connector', $newClient->name);
        self::assertSame(['payment-requests:read'], $newClient->scopes);
        self::assertNotSame($issued->clientSecret, $rotated->clientSecret);

        $this->withToken($oldToken)
            ->getJson('/services/identity')
            ->assertUnauthorized()
            ->assertDontSee($issued->clientSecret);

        $this->withToken($this->tokenFor($newClient, $rotated->clientSecret, 'payment-requests:read'))
            ->getJson('/services/identity')
            ->assertOk()
            ->assertDontSee($rotated->clientSecret);

        self::assertEqualsCanonicalizing(['issued', 'rotated'], DeveloperApplicationCredentialAudit::query()->pluck('action')->all());
    }

    public function test_rotation_rejects_preexisting_reserved_customer_pii_scope_without_disclosing_new_secret(): void
    {
        $operator = $this->financialOperator('00000000-0000-4000-8000-000000000209');
        $client = app(ClientRepository::class)->createClientCredentialsGrantClient('Imported PII connector');
        $client->forceFill(['scopes' => ['payment-requests:read', 'customers:pii:read']])->save();
        $application = DeveloperApplication::query()->create([
            'organization_id' => $operator->organization_id,
            'name' => 'Imported PII connector',
            'oauth_client_id' => $client->getKey(),
        ]);

        try {
            app(ManageDeveloperApplicationCredentials::class)->rotate($operator, $application);
            self::fail('Reserved customer PII scopes must require separate authorization before rotation can issue a new secret.');
        } catch (AuthorizationException) {
            self::assertSame($client->getKey(), $application->refresh()->oauth_client_id);
            self::assertFalse((bool) $client->refresh()->revoked);
            self::assertDatabaseCount('oauth_clients', 1);
            self::assertDatabaseCount('developer_application_credential_audits', 0);
        }
    }

    public function test_reserved_scope_enforcement_uses_configuration(): void
    {
        $operator = $this->financialOperator('00000000-0000-4000-8000-000000000210');
        $serviceScopes = [
            'payment-requests:read' => 'Read payment requests.',
            'ledger:export' => 'Export ledger evidence.',
        ];

        config()->set('openpay.service_scopes', $serviceScopes);
        config()->set('openpay.reserved_service_scopes', ['ledger:export']);
        Passport::tokensCan($serviceScopes);

        $manager = app(ManageDeveloperApplicationCredentials::class);

        self::assertArrayNotHasKey('ledger:export', $manager->availableScopes());

        try {
            $manager->issue($operator, 'Reserved export connector', ['ledger:export']);
            self::fail('Configured reserved scopes must not be granted through ordinary developer credential issuance.');
        } catch (AuthorizationException) {
            self::assertDatabaseCount('oauth_clients', 0);
            self::assertDatabaseCount('developer_applications', 0);
            self::assertDatabaseCount('developer_application_credential_audits', 0);
        }
    }

    public function test_revocation_blocks_existing_tokens_and_other_organizations_cannot_manage_the_application(): void
    {
        $operator = $this->financialOperator('00000000-0000-4000-8000-000000000203');
        $otherOperator = $this->financialOperator('00000000-0000-4000-8000-000000000204');
        $issued = app(ManageDeveloperApplicationCredentials::class)->issue($operator, 'Statements connector', ['payment-requests:read']);
        $client = $issued->application->oauthClient()->firstOrFail();
        $token = $this->tokenFor($client, $issued->clientSecret, 'payment-requests:read');

        try {
            app(ManageDeveloperApplicationCredentials::class)->revoke($otherOperator, $issued->application);
            self::fail('Cross-organization revocation must be rejected.');
        } catch (AuthorizationException) {
            self::assertFalse((bool) $client->refresh()->revoked);
        }

        app(ManageDeveloperApplicationCredentials::class)->revoke($operator, $issued->application);

        self::assertTrue((bool) $client->refresh()->revoked);
        $this->withToken($token)->getJson('/services/identity')->assertUnauthorized();
        self::assertEqualsCanonicalizing(['issued', 'revoked'], DeveloperApplicationCredentialAudit::query()->pluck('action')->all());
    }

    public function test_service_token_usage_tracking_is_debounced(): void
    {
        $operator = $this->financialOperator('00000000-0000-4000-8000-000000000207');
        $issued = app(ManageDeveloperApplicationCredentials::class)->issue($operator, 'Usage connector', ['payment-requests:read']);
        $client = $issued->application->oauthClient()->firstOrFail();
        $token = $this->tokenFor($client, $issued->clientSecret, 'payment-requests:read');
        $firstUsedAt = CarbonImmutable::parse('2026-09-06 12:00:00 UTC');

        $this->travelTo($firstUsedAt);
        $this->withToken($token)->getJson('/services/identity')->assertOk();
        self::assertTrue($client->refresh()->last_used_at->equalTo($firstUsedAt));

        $this->travelTo($firstUsedAt->addSeconds(30));
        $this->withToken($token)->getJson('/services/identity')->assertOk();
        self::assertTrue($client->refresh()->last_used_at->equalTo($firstUsedAt));

        $refreshedAt = $firstUsedAt->addSeconds(61);
        $this->travelTo($refreshedAt);
        $this->withToken($token)->getJson('/services/identity')->assertOk();
        self::assertTrue($client->refresh()->last_used_at->equalTo($refreshedAt));
    }

    public function test_filament_management_delivers_new_secret_without_public_component_state(): void
    {
        $operator = $this->financialOperator('00000000-0000-4000-8000-000000000205');
        $dispatchedSecret = null;

        $page = Livewire::actingAs($operator)
            ->test(ManageDeveloperApplications::class)
            ->callAction('issueDeveloperApplication', data: [
                'name' => 'Reporting connector',
                'scopes' => ['payment-requests:read'],
            ])
            ->assertHasNoFormErrors()
            ->assertDispatched('developer-application-credentials-issued', function (string $eventName, array $params) use (&$dispatchedSecret): bool {
                $dispatchedSecret = (string) ($params['clientSecret'] ?? '');

                return $eventName === 'developer-application-credentials-issued'
                    && (string) ($params['clientId'] ?? '') !== ''
                    && $dispatchedSecret !== '';
            })
            ->assertSee('New client secret')
            ->assertSee('Reporting connector')
            ->assertSee('payment-requests:read')
            ->assertDontSee('customers:pii:read');

        self::assertNotSame('', $dispatchedSecret);
        self::assertNotSame($dispatchedSecret, DeveloperApplication::query()->sole()->oauthClient()->firstOrFail()->secret);
        self::assertFalse((new ReflectionClass(ManageDeveloperApplications::class))->hasProperty('revealedClientSecret'));

        Livewire::actingAs($operator)
            ->test(ManageDeveloperApplications::class)
            ->assertSee('Reporting connector')
            ->assertSee('Never')
            ->assertDontSee($dispatchedSecret);
    }

    public function test_credential_audit_survives_actor_account_deletion(): void
    {
        $operator = $this->financialOperator('00000000-0000-4000-8000-000000000206');
        $actorId = $operator->getKey();

        app(ManageDeveloperApplicationCredentials::class)->issue($operator, 'Retained audit connector', ['payment-requests:read']);

        $operator->delete();

        $audit = DeveloperApplicationCredentialAudit::query()->sole();
        self::assertNull($audit->actor_user_id);
        self::assertSame((string) $actorId, $audit->actor_user_identifier);
        self::assertSame('issued', $audit->action);
    }

    public function test_audit_history_uses_organization_sequence_to_order_events_with_tied_timestamps(): void
    {
        $operator = $this->financialOperator('00000000-0000-4000-8000-000000000208');
        CarbonImmutable::setTestNow(CarbonImmutable::parse('2026-09-06 12:00:00 UTC'));

        try {
            $issued = app(ManageDeveloperApplicationCredentials::class)->issue($operator, 'Ordered audit connector', ['payment-requests:read']);
            app(ManageDeveloperApplicationCredentials::class)->rotate($operator, $issued->application);
            app(ManageDeveloperApplicationCredentials::class)->revoke($operator, $issued->application->refresh());

            $actions = Livewire::actingAs($operator)
                ->test(ManageDeveloperApplications::class)
                ->instance()
                ->auditHistory()
                ->pluck('action')
                ->all();
        } finally {
            CarbonImmutable::setTestNow();
        }

        self::assertSame(['revoked', 'rotated', 'issued'], $actions);
        self::assertSame(
            ['Ordered audit connector', 'Ordered audit connector', 'Ordered audit connector'],
            Livewire::actingAs($operator)
                ->test(ManageDeveloperApplications::class)
                ->instance()
                ->auditHistory()
                ->map(fn (DeveloperApplicationCredentialAudit $audit): ?string => $audit->developerApplication?->name)
                ->all(),
        );
        self::assertSame(
            [1, 2, 3],
            DeveloperApplicationCredentialAudit::query()
                ->orderBy('organization_sequence')
                ->pluck('organization_sequence')
                ->all(),
        );
    }

    public function test_credential_audit_migration_uses_portable_index_names(): void
    {
        $migration = file_get_contents(database_path('migrations/2026_09_09_000000_manage_developer_application_credentials.php'));
        self::assertIsString($migration);

        foreach ([
            'dev_app_cred_audits_org_idx',
            'dev_app_cred_audits_app_idx',
            'dev_app_cred_audits_client_idx',
            'dev_app_cred_audits_org_seq_unique',
        ] as $name) {
            self::assertLessThanOrEqual(64, strlen($name));
            self::assertStringContainsString("'".$name."'", $migration);
        }

        self::assertStringNotContainsString("->unique(['organization_id', 'organization_sequence']);", $migration);
    }

    public function test_audit_sequence_read_uses_a_current_locking_query(): void
    {
        $method = new ReflectionMethod(ManageDeveloperApplicationCredentials::class, 'auditSequenceQuery');
        $query = $method->invoke(app(ManageDeveloperApplicationCredentials::class), '00000000-0000-4000-8000-000000000208');
        self::assertInstanceOf(Builder::class, $query);

        $baseQuery = $query->getQuery();

        self::assertTrue($baseQuery->lock);
        self::assertSame('developer_application_credential_audits', $baseQuery->from);
        self::assertSame('organization_id', $baseQuery->wheres[0]['column']);
        self::assertSame('organization_sequence', $baseQuery->orders[0]['column']);
        self::assertSame('desc', $baseQuery->orders[0]['direction']);
    }

    private function financialOperator(string $organizationId): User
    {
        Organization::query()->forceCreate(['id' => $organizationId]);

        return User::factory()->create([
            'organization_id' => $organizationId,
            'is_financial_operator' => true,
            'two_factor_confirmed_at' => now(),
            'recovery_codes_confirmed_at' => now(),
        ]);
    }

    private function tokenFor(Client $client, string $secret, string $scope): string
    {
        return (string) $this->postJson('/oauth/token', [
            'grant_type' => 'client_credentials',
            'client_id' => $client->getKey(),
            'client_secret' => $secret,
            'scope' => $scope,
        ])->assertOk()
            ->assertDontSee($secret)
            ->json('access_token');
    }
}
