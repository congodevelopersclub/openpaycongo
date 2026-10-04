<?php

namespace Tests\Feature;

use App\DeveloperApplications\CustomerWalletAccess;
use App\DeveloperApplications\ManageDeveloperApplicationCredentials;
use App\Models\Customer;
use App\Models\CustomerCredit;
use App\Models\Deposit;
use App\Models\Organization;
use App\Models\SourceInstallation;
use App\Models\User;
use App\Security\FinancialOperatorMfaSession;
use Illuminate\Database\Eloquent\ModelNotFoundException;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Artisan;
use Laravel\Sanctum\Sanctum;
use Tests\TestCase;

final class CustomerWalletApiTest extends TestCase
{
    use RefreshDatabase;

    public function test_authenticated_deposit_retry_updates_one_wallet_and_requires_explicit_customer_access(): void
    {
        Artisan::call('passport:keys', ['--force' => true]);
        $this->mock(FinancialOperatorMfaSession::class)->shouldReceive('assertVerified')->andReturnNull();
        $organization = Organization::query()->forceCreate([]);
        $actor = User::factory()->create(['organization_id' => $organization->id, 'is_financial_operator' => true]);
        $installation = SourceInstallation::query()->create([
            'organization_id' => $organization->id,
            'installation_digest' => str_repeat('a', 64),
        ]);
        Sanctum::actingAs($installation, ['mobile:deposits:write'], 'mobile');
        $payload = [
            'customer_lookup_identifier' => 'synthetic-wallet-customer',
            'provider_reference' => 'synthetic-wallet-reference',
            'amount_minor' => 12500,
            'currency' => 'CDF',
            'provider_occurred_at' => '2026-08-31T01:00:00Z',
        ];
        $this->postJson('/mobile/deposits', $payload)->assertCreated();
        $this->postJson('/mobile/deposits', $payload)->assertOk()->assertJsonPath('outcome', 'replayed');
        $this->postJson('/mobile/deposits', [...$payload, 'amount_minor' => 12600])->assertConflict();
        self::assertDatabaseCount('deposits', 1);
        self::assertDatabaseCount('ledger_entries', 2);
        self::assertDatabaseCount('customer_credit_postings', 1);
        self::assertSame(12500, CustomerCredit::query()->value('available_minor'));
        $customer = Customer::query()->sole();
        $issued = app(ManageDeveloperApplicationCredentials::class)->issue($actor, 'Synthetic wallet consumer', ['wallets:read']);
        $token = (string) $this->postJson('/oauth/token', [
            'grant_type' => 'client_credentials', 'client_id' => $issued->clientId,
            'client_secret' => $issued->clientSecret, 'scope' => 'wallets:read',
        ])->assertOk()->json('access_token');
        $url = '/services/customers/'.$customer->id.'/wallet';
        $this->withToken($token)->getJson($url)->assertNotFound();
        app(CustomerWalletAccess::class)->change($actor, $issued->application->id, $customer->id, true);
        $this->withToken($token)->getJson($url)->assertOk()
            ->assertExactJson([
                'customer_id' => $customer->id, 'settlement_status' => 'unverified',
                'balances' => [['currency' => 'CDF', 'available_minor' => 12500]],
            ])->assertHeader('cache-control', 'no-store, private')
            ->assertDontSee($payload['customer_lookup_identifier'])->assertDontSee($payload['provider_reference']);
        app(CustomerWalletAccess::class)->change($actor, $issued->application->id, $customer->id, false);
        $this->withToken($token)->getJson($url)->assertNotFound();
        app(ManageDeveloperApplicationCredentials::class)->revoke($actor, $issued->application);
        $this->withToken($token)->getJson($url)->assertUnauthorized();
        self::assertSame(12500, CustomerCredit::query()->value('available_minor'));
        self::assertSame($installation->id, Deposit::query()->sole()->source_installation_id);
    }

    public function test_wallet_access_cannot_be_granted_across_organizations(): void
    {
        $this->mock(FinancialOperatorMfaSession::class)->shouldReceive('assertVerified')->andReturnNull();
        $organization = Organization::query()->forceCreate([]);
        $other = Organization::query()->forceCreate([]);
        $actor = User::factory()->create(['organization_id' => $organization->id, 'is_financial_operator' => true]);
        $issued = app(ManageDeveloperApplicationCredentials::class)->issue($actor, 'Scoped consumer', ['wallets:read']);
        $customer = Customer::query()->create(['organization_id' => $other->id, 'private_lookup_digest' => str_repeat('b', 64)]);
        $this->expectException(ModelNotFoundException::class);
        app(CustomerWalletAccess::class)->change($actor, $issued->application->id, $customer->id, true);
    }
}
