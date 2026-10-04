<?php

namespace Tests\Support;

use App\Deposits\ProviderTransfer;
use App\Deposits\RecordProviderDeposit;
use App\DeveloperApplications\ManageDeveloperApplicationCredentials;
use App\Models\Customer;
use App\Models\Deposit;
use App\Models\DeveloperApplication;
use App\Models\DeveloperCustomerAccess;
use App\Models\Organization;
use App\Models\SourceInstallation;
use App\Models\User;
use App\Models\WebhookEndpoint;
use App\Security\FinancialOperatorMfaSession;
use App\Webhooks\ManageWebhookEndpoint;
use App\Webhooks\WebhookDnsResolver;
use Illuminate\Support\Facades\Queue;
use Mockery;
use Tests\TestCase;

abstract class WalletWebhookTestCase extends TestCase
{
    protected const SECRET = 'synthetic-webhook-secret-only-for-tests-123456';

    /** @return array{User, DeveloperApplication, Customer, Deposit, WebhookEndpoint} */
    protected function fixture(string $url = 'https://receiver.example/wallet'): array
    {
        Queue::fake();
        config(['webhooks.allowed_hosts' => ['receiver.example']]);
        $this->app->instance(FinancialOperatorMfaSession::class, new class implements FinancialOperatorMfaSession
        {
            public function assertVerified(User $user): void {}
        });
        $organization = Organization::query()->forceCreate([]);
        $actor = User::factory()->create(['organization_id' => $organization->id, 'is_financial_operator' => true]);
        $application = app(ManageDeveloperApplicationCredentials::class)->issue($actor, 'Synthetic webhook consumer', ['wallets:read'])->application;
        $customer = app(RecordProviderDeposit::class)->registerCustomer($organization->id, 'synthetic-webhook-customer');
        DeveloperCustomerAccess::query()->create(['developer_application_id' => $application->id, 'customer_id' => $customer->id, 'granted_by_user_id' => $actor->id]);
        $endpoint = app(ManageWebhookEndpoint::class)->configure($actor, $application->id, $url, self::SECRET, true);
        $installation = SourceInstallation::query()->create(['organization_id' => $organization->id, 'installation_digest' => str_repeat('b', 64)]);
        $deposit = app(RecordProviderDeposit::class)->record(new ProviderTransfer(
            organizationId: $organization->id,
            installationIdentifier: 'synthetic-webhook-installation',
            customerLookupIdentifier: 'synthetic-webhook-customer',
            providerReference: 'synthetic-webhook-reference',
            amountMinor: 12500,
            currency: 'CDF',
            providerOccurredAt: '2026-08-31T01:00:00Z',
            senderIdentifier: null,
            receiverIdentifier: null,
        ), $installation)->deposit;

        return [$actor, $application, $customer, $deposit, $endpoint];
    }

    /** @param string[] $addresses */
    protected function dns(array $addresses): void
    {
        $resolver = Mockery::mock(WebhookDnsResolver::class);
        $resolver->shouldReceive('resolve')->andReturn($addresses);
        $this->app->instance(WebhookDnsResolver::class, $resolver);
    }
}
