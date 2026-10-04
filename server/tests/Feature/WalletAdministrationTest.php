<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\DeveloperApplications\ManageDeveloperApplicationCredentials;
use App\Filament\Pages\ManageDeveloperApplications;
use App\Models\Customer;
use App\Models\Organization;
use App\Models\User;
use App\Models\WalletWebhookDelivery;
use App\Security\FinancialOperatorMfaSession;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Queue;
use Livewire\Livewire;
use Tests\Support\WalletWebhookTestCase;

final class WalletAdministrationTest extends WalletWebhookTestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        Artisan::call('passport:keys', ['--force' => true]);
        Filament::setCurrentPanel(Filament::getPanel('operations'));
        config(['webhooks.allowed_hosts' => ['receiver.example']]);
        Queue::fake();
        $this->app->instance(FinancialOperatorMfaSession::class, new class implements FinancialOperatorMfaSession {
            public function assertVerified(User $user): void {}
        });
    }

    public function test_customer_provisioning_action_grants_access_without_creating_a_deposit_or_balance(): void
    {
        $actor = $this->financialOperator();
        $application = app(ManageDeveloperApplicationCredentials::class)
            ->issue($actor, 'Wallet review connector', ['wallets:read'])->application;
        $lookup = 'synthetic-admin-customer-lookup-only';

        Livewire::actingAs($actor)
            ->test(ManageDeveloperApplications::class)
            ->callAction('customerWalletAccess',
                data: ['customer_lookup_identifier' => $lookup, 'grant' => true],
                arguments: ['application' => $application->id],
            )
            ->assertHasNoFormErrors()
            ->assertDontSee($lookup);

        $customer = Customer::query()->sole();
        self::assertSame($actor->organization_id, $customer->organization_id);
        $this->assertDatabaseCount('developer_customer_accesses', 1);
        $this->assertDatabaseHas('developer_customer_accesses', [
            'developer_application_id' => $application->id,
            'customer_id' => $customer->id,
            'granted_by_user_id' => $actor->id,
        ]);
        $this->assertDatabaseCount('deposits', 0);
        $this->assertDatabaseCount('customer_credit_postings', 0);
    }

    public function test_webhook_controls_configure_pause_and_replay_while_the_status_list_hides_private_values(): void
    {
        [$actor, $application, , $deposit, $endpoint] = $this->fixture();
        $secret = 'synthetic-ui-signing-secret-only-for-tests-12345';
        $privateMarker = 'synthetic-webhook-private-payload-marker';
        $delivery = WalletWebhookDelivery::query()->create([
            'webhook_endpoint_id' => $endpoint->id,
            'deposit_id' => $deposit->id,
            'event_id' => '00000000-0000-4000-8000-000000000091',
            'body' => json_encode(['private' => $privateMarker], JSON_THROW_ON_ERROR),
            'status' => 'dead_letter',
            'attempts' => 8,
            'last_error_code' => 'http_503',
        ]);
        $page = Livewire::actingAs($actor)->test(ManageDeveloperApplications::class);

        $page->callAction('configureWebhook', data: [
            'url' => 'https://receiver.example/wallet',
            'signing_secret' => $secret,
            'enabled' => true,
        ], arguments: ['application' => $application->id])->assertHasNoFormErrors();

        $endpoint->refresh();
        self::assertTrue($endpoint->enabled);
        self::assertNotSame($secret, $endpoint->getRawOriginal('signing_secret'));

        $page->callAction('pauseWebhook', arguments: ['application' => $application->id]);
        self::assertFalse($endpoint->fresh()->enabled);

        $page->callAction('configureWebhook', data: [
            'url' => 'https://receiver.example/wallet',
            'signing_secret' => $secret,
            'enabled' => true,
        ], arguments: ['application' => $application->id])->assertHasNoFormErrors();

        $page->callAction('replayWebhook', arguments: [
            'application' => $application->id,
            'delivery' => $delivery->id,
        ]);

        self::assertSame('pending', $delivery->fresh()->status);
        self::assertSame(0, $delivery->fresh()->attempts);
        $page->assertSee($delivery->event_id)
            ->assertSee('pending')
            ->assertDontSee($secret)
            ->assertDontSee('https://receiver.example/wallet')
            ->assertDontSee('synthetic-webhook-customer')
            ->assertDontSee('synthetic-webhook-reference')
            ->assertDontSee($privateMarker);
    }

    public function test_page_actions_reject_an_application_id_from_another_organization(): void
    {
        $actor = $this->financialOperator();
        $foreignActor = $this->financialOperator();
        $foreignApplication = app(ManageDeveloperApplicationCredentials::class)
            ->issue($foreignActor, 'Foreign wallet connector', ['wallets:read'])->application;

        Livewire::actingAs($actor)
            ->test(ManageDeveloperApplications::class)
            ->assertDontSee($foreignApplication->name)
            ->callAction('customerWalletAccess',
                data: ['customer_lookup_identifier' => 'foreign-lookup-should-not-be-used', 'grant' => true],
                arguments: ['application' => $foreignApplication->id],
            )
            ->assertNotFound();

        Livewire::actingAs($actor)
            ->test(ManageDeveloperApplications::class)
            ->callAction('configureWebhook', data: [
                'url' => 'https://receiver.example/wallet',
                'signing_secret' => 'synthetic-cross-tenant-secret-only-for-tests',
                'enabled' => true,
            ], arguments: ['application' => $foreignApplication->id])
            ->assertNotFound();

        Livewire::actingAs($actor)
            ->test(ManageDeveloperApplications::class)
            ->callAction('pauseWebhook', arguments: ['application' => $foreignApplication->id])
            ->assertNotFound();

        Livewire::actingAs($actor)
            ->test(ManageDeveloperApplications::class)
            ->callAction('replayWebhook', arguments: [
                'application' => $foreignApplication->id,
                'delivery' => '00000000-0000-4000-8000-000000000099',
            ])
            ->assertNotFound();
    }

    private function financialOperator(): User
    {
        $organization = Organization::query()->forceCreate([]);

        return User::factory()->create([
            'organization_id' => $organization->id,
            'is_financial_operator' => true,
            'two_factor_confirmed_at' => now(),
            'recovery_codes_confirmed_at' => now(),
        ]);
    }
}
