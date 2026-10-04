<?php

namespace Tests\Feature;

use App\Jobs\DeliverWalletWebhook;
use App\Models\DeveloperCustomerAccess;
use App\Models\Organization;
use App\Models\User;
use App\Models\WalletWebhookDelivery;
use App\PaymentRequests\AllocatePendingPaymentRequests;
use App\Security\FinancialOperatorMfaSession;
use App\Webhooks\ManageWebhookEndpoint;
use App\Webhooks\SendWalletWebhook;
use App\Webhooks\WebhookDestinationPolicy;
use Illuminate\Auth\Access\AuthorizationException;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\Client\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Queue;
use InvalidArgumentException;
use Tests\Support\WalletWebhookTestCase;

final class WalletWebhookDeliveryTest extends WalletWebhookTestCase
{
    use RefreshDatabase;

    public function test_committed_credit_records_one_private_minimal_payload_and_signs_exact_body(): void
    {
        [, , $customer, $deposit, $endpoint] = $this->fixture();
        $this->dns(['8.8.8.8']);
        Http::fake(['receiver.example/*' => Http::response('', 202)]);
        app(AllocatePendingPaymentRequests::class)->forDeposit($deposit);
        app(AllocatePendingPaymentRequests::class)->forDeposit($deposit);
        $delivery = WalletWebhookDelivery::query()->sole();
        self::assertSame([
            'event_id' => $delivery->event_id, 'type' => 'wallet.credit_posted', 'customer_id' => $customer->id,
            'deposit_id' => $deposit->id, 'amount_minor' => 12500, 'currency' => 'CDF', 'available_minor' => 12500, 'settlement_status' => 'unverified',
        ], json_decode($delivery->body, true, flags: JSON_THROW_ON_ERROR));
        self::assertNotSame(self::SECRET, $endpoint->getRawOriginal('signing_secret'));
        self::assertArrayNotHasKey('signing_secret', $endpoint->toArray());
        Queue::assertPushed(DeliverWalletWebhook::class, fn ($job) => $job->deliveryId === $delivery->id && $job->afterCommit === true);
        $this->deliver($delivery);
        $this->deliver($delivery);
        Http::assertSentCount(1);
        Http::assertSent(function (Request $request) use ($delivery): bool {
            $timestamp = $request->header('Webhook-Timestamp')[0];

            return $request->body() === $delivery->body
                && $request->header('Webhook-Id') === [$delivery->event_id]
                && $request->header('Webhook-Signature') === ['v1='.hash_hmac('sha256', $timestamp.'.'.$delivery->body, self::SECRET)];
        });
        self::assertSame('delivered', $delivery->fresh()->status);
    }

    public function test_rollback_leaves_no_credit_posting_or_webhook_and_ungranted_apps_receive_nothing(): void
    {
        [, , , $deposit] = $this->fixture();
        DB::beginTransaction();
        app(AllocatePendingPaymentRequests::class)->forDeposit($deposit);
        self::assertDatabaseCount('wallet_webhook_deliveries', 1);
        DB::rollBack();
        self::assertDatabaseCount('wallet_webhook_deliveries', 0);
        self::assertDatabaseCount('customer_credit_postings', 0);
        DeveloperCustomerAccess::query()->delete();
        app(AllocatePendingPaymentRequests::class)->forDeposit($deposit);
        self::assertDatabaseCount('wallet_webhook_deliveries', 0);
    }

    public function test_retries_keep_event_and_body_and_end_in_replayable_dead_letter(): void
    {
        [$actor, $application, , $deposit] = $this->fixture();
        $this->dns(['8.8.8.8']);
        Http::fake(['receiver.example/*' => Http::response('must not retain this response', 503)]);
        app(AllocatePendingPaymentRequests::class)->forDeposit($deposit);
        $delivery = WalletWebhookDelivery::query()->sole();
        $eventId = $delivery->event_id;
        $body = $delivery->body;
        for ($attempt = 1; $attempt <= DeliverWalletWebhook::MAX_ATTEMPTS; $attempt++) {
            $this->deliver($delivery);
            $delivery->refresh();
            self::assertSame($attempt, $delivery->attempts);
            self::assertSame($eventId, $delivery->event_id);
            self::assertSame($body, $delivery->body);
            self::assertSame('http_503', $delivery->last_error_code);
            if ($attempt < DeliverWalletWebhook::MAX_ATTEMPTS) {
                self::assertSame('retry', $delivery->status);
                self::assertSame(min(3600, 30 * (2 ** ($attempt - 1))), (int) round(now()->diffInSeconds($delivery->next_attempt_at, false)));
                $this->travelTo($delivery->next_attempt_at);
            }
        }
        self::assertSame('dead_letter', $delivery->status);
        $this->deliver($delivery);
        Http::assertSentCount(8);
        $replayed = app(ManageWebhookEndpoint::class)->replay($actor, $application->id, $delivery->id);
        self::assertSame($eventId, $replayed->event_id);
        self::assertSame($body, $replayed->body);
        self::assertSame(0, $replayed->attempts);
    }

    public function test_pause_revocation_redirect_and_claim_recovery_preserve_delivery_boundaries(): void
    {
        [$actor, $application, , $deposit, $endpoint] = $this->fixture();
        $this->dns(['8.8.8.8']);
        Http::fake(['receiver.example/*' => Http::response('', 302, ['Location' => 'http://127.0.0.1/private'])]);
        app(AllocatePendingPaymentRequests::class)->forDeposit($deposit);
        $delivery = WalletWebhookDelivery::query()->sole();
        $delivery->forceFill(['claimed_at' => now(), 'claim_token' => '00000000-0000-4000-8000-000000000099'])->save();
        $this->deliver($delivery);
        Http::assertNothingSent();
        $delivery->forceFill(['claimed_at' => now()->subMinutes(6)])->save();
        $this->artisan('wallet-webhooks:recover-deliveries')->assertSuccessful();
        Queue::assertPushed(DeliverWalletWebhook::class);
        $this->deliver($delivery);
        self::assertSame('redirect_rejected', $delivery->fresh()->last_error_code);
        Http::assertSentCount(1);
        $this->travelTo($delivery->fresh()->next_attempt_at);
        app(ManageWebhookEndpoint::class)->pause($actor, $application->id);
        $this->deliver($delivery);
        Http::assertSentCount(1);
        $endpoint->forceFill(['enabled' => true])->save();
        DeveloperCustomerAccess::query()->delete();
        $this->deliver($delivery);
        self::assertSame('cancelled', $delivery->fresh()->status);
        Http::assertSentCount(1);
    }

    public function test_revoked_application_or_wrong_tenant_is_never_sent(): void
    {
        [, $application, , $deposit] = $this->fixture();
        Http::preventStrayRequests();
        app(AllocatePendingPaymentRequests::class)->forDeposit($deposit);
        $delivery = WalletWebhookDelivery::query()->sole();
        $application->oauthClient()->firstOrFail()->forceFill(['revoked' => true])->save();
        $this->deliver($delivery);
        self::assertSame('cancelled', $delivery->fresh()->status);
        Http::assertNothingSent();
        $delivery->forceFill(['status' => 'pending'])->save();
        $application->forceFill(['organization_id' => Organization::query()->forceCreate([])->id])->save();
        $this->deliver($delivery);
        self::assertSame('authorization_revoked', $delivery->fresh()->last_error_code);
        Http::assertNothingSent();
    }

    public function test_destination_policy_rejects_unsafe_urls_and_every_private_dns_answer_without_http(): void
    {
        $this->fixture();
        Http::preventStrayRequests();
        foreach (['http://receiver.example/wallet', 'https://receiver.example:8443/wallet', 'https://user:pass@receiver.example/wallet', 'https://receiver.example/wallet?token=secret', 'https://receiver.example/#secret', 'https://unlisted.example/wallet', 'https://127.0.0.1/wallet'] as $url) {
            try {
                app(WebhookDestinationPolicy::class)->validateUrl($url);
                self::fail('Unsafe URL accepted.');
            } catch (InvalidArgumentException $exception) {
                self::assertSame('destination_rejected', $exception->getMessage());
            }
        }
        foreach (['127.0.0.1', '169.254.169.254', '10.0.0.1', '100.64.0.1', '224.0.0.1', '192.0.2.1', '::1', '::ffff:8.8.8.8', '2001:db8::1', 'fd00::1'] as $ip) {
            $this->dns(['8.8.8.8', $ip]);
            try {
                app(WebhookDestinationPolicy::class)->resolve('https://receiver.example/wallet');
                self::fail('Private DNS answer accepted.');
            } catch (InvalidArgumentException $exception) {
                self::assertSame('destination_address_rejected', $exception->getMessage());
            }
        }
        Http::assertNothingSent();
    }

    public function test_endpoint_mutation_requires_existing_verified_mfa_and_tenant_actor(): void
    {
        [$actor, $application] = $this->fixture();
        $otherActor = User::factory()->create(['organization_id' => Organization::query()->forceCreate([])->id, 'is_financial_operator' => true]);
        try {
            app(ManageWebhookEndpoint::class)->configure($otherActor, $application->id, 'https://receiver.example/wallet', self::SECRET, true);
            self::fail('Cross-tenant configuration accepted.');
        } catch (AuthorizationException) {
            self::assertTrue(true);
        }
        $this->app->instance(FinancialOperatorMfaSession::class, new class implements FinancialOperatorMfaSession
        {
            public function assertVerified(User $user): void
            {
                throw new AuthorizationException;
            }
        });
        $this->expectException(AuthorizationException::class);
        app(ManageWebhookEndpoint::class)->pause($actor, $application->id);
    }

    public function test_retry_replay_does_not_steal_a_live_claim_and_keeps_a_stale_delivery_id(): void
    {
        [$actor, $application, , $deposit] = $this->fixture();
        app(AllocatePendingPaymentRequests::class)->forDeposit($deposit);
        $delivery = WalletWebhookDelivery::query()->sole();
        $delivery->forceFill(['status' => 'retry', 'claimed_at' => now(), 'claim_token' => '00000000-0000-4000-8000-000000000099'])->save();
        try {
            app(ManageWebhookEndpoint::class)->replay($actor, $application->id, $delivery->id);
            self::fail('An active claim was replayed.');
        } catch (InvalidArgumentException) {
            self::assertSame('retry', $delivery->fresh()->status);
        }
        $delivery->forceFill(['claimed_at' => now()->subMinutes(6)])->save();
        $replayed = app(ManageWebhookEndpoint::class)->replay($actor, $application->id, $delivery->id);
        self::assertSame($delivery->event_id, $replayed->event_id);
        self::assertSame($delivery->body, $replayed->body);
        self::assertSame('pending', $replayed->status);
        self::assertNull($replayed->claimed_at);
    }

    private function deliver(WalletWebhookDelivery $delivery): void
    {
        (new DeliverWalletWebhook($delivery->id))->handle(app(SendWalletWebhook::class));
    }
}
