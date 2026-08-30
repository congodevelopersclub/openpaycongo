<?php

namespace Tests\Feature;

use App\Events\PaymentRequestAllocated;
use App\Jobs\DispatchPaymentRequestAllocation;
use App\Models\Customer;
use App\Models\CustomerCredit;
use App\Models\Deposit;
use App\Models\PaymentRequest;
use App\Models\PaymentRequestAllocationDelivery;
use App\Models\SourceInstallation;
use App\PaymentRequests\AllocatePendingPaymentRequests;
use App\PaymentRequests\CreatePaymentRequest;
use App\PaymentRequests\PaymentRequestStatus;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Event;
use Illuminate\Support\Facades\Queue;
use InvalidArgumentException;
use Tests\TestCase;

final class PaymentRequestTest extends TestCase
{
    use RefreshDatabase;

    public function test_it_charges_sufficient_customer_credit_without_an_organization_scope(): void
    {
        $customer = Customer::query()->create($this->customerAttributes());
        CustomerCredit::query()->create([
            'customer_id' => $customer->id,
            'currency' => 'CDF',
            'available_minor' => 1200,
        ]);

        $request = app(CreatePaymentRequest::class)->create($customer->id, 1200, 'CDF', 'charged-request');

        self::assertSame(PaymentRequestStatus::Charged, $request->status);
        self::assertSame(0, $request->remaining_minor);
        self::assertNull($request->organization_id ?? null);
        self::assertSame(0, CustomerCredit::query()->where('customer_id', $customer->id)->value('available_minor'));
    }

    public function test_allocation_delivery_is_persisted_with_the_credit_charge_and_enqueued_after_commit(): void
    {
        Queue::fake();
        $customer = Customer::query()->create($this->customerAttributes());
        CustomerCredit::query()->create(['customer_id' => $customer->id, 'currency' => 'CDF', 'available_minor' => 1200]);

        DB::transaction(function () use ($customer): void {
            app(CreatePaymentRequest::class)->create($customer->id, 1200, 'CDF', 'commit-before-dispatch');
            self::assertDatabaseCount('payment_request_allocation_deliveries', 1);
        });

        Queue::assertPushed(DispatchPaymentRequestAllocation::class);
    }

    public function test_it_keeps_an_insufficient_request_pending_until_credit_arrives(): void
    {
        $customer = Customer::query()->create($this->customerAttributes());
        CustomerCredit::query()->create([
            'customer_id' => $customer->id,
            'currency' => 'CDF',
            'available_minor' => 1199,
        ]);

        $request = app(CreatePaymentRequest::class)->create($customer->id, 1200, 'CDF', 'pending-request');

        self::assertSame(PaymentRequestStatus::Pending, $request->status);
        self::assertSame(1200, $request->remaining_minor);
        self::assertSame(1199, CustomerCredit::query()->where('customer_id', $customer->id)->value('available_minor'));
        self::assertTrue($request->expires_at->greaterThan(CarbonImmutable::now()->addDays(89)));
    }

    public function test_a_new_smaller_request_cannot_bypass_an_older_unexpired_shortfall(): void
    {
        $customer = Customer::query()->create($this->customerAttributes());
        CustomerCredit::query()->create(['customer_id' => $customer->id, 'currency' => 'CDF', 'available_minor' => 400]);
        $older = PaymentRequest::query()->forceCreate($this->pendingAttributes(
            $customer->id,
            '00000000-0000-4000-8000-000000000001',
            500,
            CarbonImmutable::now()->addDay(),
            CarbonImmutable::now()->subMinute(),
        ));

        $newer = app(CreatePaymentRequest::class)->create($customer->id, 300, 'CDF', 'newer-request');

        self::assertSame(PaymentRequestStatus::Pending, $older->fresh()->status);
        self::assertSame(PaymentRequestStatus::Pending, $newer->status);
        self::assertSame(400, CustomerCredit::query()->where('customer_id', $customer->id)->value('available_minor'));
    }

    public function test_deposit_credit_allocates_unexpired_pending_requests_oldest_first_with_stable_id_tie_breaking(): void
    {
        $customer = Customer::query()->create($this->customerAttributes());
        $now = CarbonImmutable::parse('2026-08-30 12:00:00');
        CarbonImmutable::setTestNow($now);
        try {
            $first = PaymentRequest::query()->forceCreate($this->pendingAttributes($customer->id, '00000000-0000-4000-8000-000000000001', 500, $now->addDay(), $now));
            $second = PaymentRequest::query()->forceCreate($this->pendingAttributes($customer->id, '00000000-0000-4000-8000-000000000002', 500, $now->addDay(), $now));
            $deposit = Deposit::query()->create($this->depositAttributes($customer->id, 500));

            app(AllocatePendingPaymentRequests::class)->forDeposit($deposit);

            self::assertSame(PaymentRequestStatus::Charged, $first->fresh()->status);
            self::assertSame(PaymentRequestStatus::Pending, $second->fresh()->status);
        } finally {
            CarbonImmutable::setTestNow();
        }
    }

    public function test_recovery_idempotently_posts_a_committed_deposit_when_queue_enqueue_was_lost(): void
    {
        $customer = Customer::query()->create($this->customerAttributes());
        $deposit = Deposit::query()->create($this->depositAttributes($customer->id, 500));

        $this->artisan('payment-requests:recover-credit')->assertExitCode(0);
        $this->artisan('payment-requests:recover-credit')->assertExitCode(0);

        self::assertSame(500, CustomerCredit::query()->where('customer_id', $customer->id)->where('currency', 'CDF')->value('available_minor'));
        self::assertDatabaseCount('customer_credit_postings', 1);
    }

    public function test_expired_requests_never_consume_later_credit_and_all_or_nothing_policy_does_not_partially_charge(): void
    {
        $customer = Customer::query()->create($this->customerAttributes());
        $now = CarbonImmutable::parse('2026-08-30 12:00:00');
        CarbonImmutable::setTestNow($now);
        try {
            $expired = PaymentRequest::query()->forceCreate($this->pendingAttributes($customer->id, '00000000-0000-4000-8000-000000000001', 500, $now->subSecond()));
            $pending = PaymentRequest::query()->forceCreate($this->pendingAttributes($customer->id, '00000000-0000-4000-8000-000000000002', 700, $now->addDay(), $now));
            $deposit = Deposit::query()->create($this->depositAttributes($customer->id, 600));

            app(AllocatePendingPaymentRequests::class)->forDeposit($deposit);

            self::assertSame(PaymentRequestStatus::Expired, $expired->fresh()->status);
            self::assertSame(PaymentRequestStatus::Pending, $pending->fresh()->status);
            self::assertSame(600, CustomerCredit::query()->where('customer_id', $customer->id)->value('available_minor'));
        } finally {
            CarbonImmutable::setTestNow();
        }
    }

    public function test_credit_currencies_are_isolated(): void
    {
        $customer = Customer::query()->create($this->customerAttributes());
        CustomerCredit::query()->create([
            'customer_id' => $customer->id,
            'currency' => 'USD',
            'available_minor' => 1200,
        ]);

        $request = app(CreatePaymentRequest::class)->create($customer->id, 1200, 'CDF', 'currency-isolation');

        self::assertSame(PaymentRequestStatus::Pending, $request->status);
        self::assertSame(1200, CustomerCredit::query()->where('customer_id', $customer->id)->where('currency', 'USD')->value('available_minor'));
    }

    public function test_an_iso_shaped_but_unsupported_currency_is_rejected_before_creating_a_pending_request(): void
    {
        $customer = Customer::query()->create($this->customerAttributes());

        $this->expectException(InvalidArgumentException::class);
        try {
            app(CreatePaymentRequest::class)->create($customer->id, 1200, 'USD', 'unsupported-currency');
        } finally {
            self::assertDatabaseCount('payment_requests', 0);
        }
    }

    public function test_an_identical_idempotency_replay_returns_the_original_request_without_a_second_debit(): void
    {
        $customer = Customer::query()->create($this->customerAttributes());
        CustomerCredit::query()->create(['customer_id' => $customer->id, 'currency' => 'CDF', 'available_minor' => 1200]);

        $first = app(CreatePaymentRequest::class)->create($customer->id, 1200, 'CDF', 'opaque-replay-key');
        $replay = app(CreatePaymentRequest::class)->create($customer->id, 1200, 'CDF', 'opaque-replay-key');

        self::assertSame($first->id, $replay->id);
        self::assertDatabaseCount('payment_requests', 1);
        self::assertSame(0, CustomerCredit::query()->where('customer_id', $customer->id)->value('available_minor'));
    }

    public function test_an_idempotency_key_cannot_be_reused_with_a_changed_payload(): void
    {
        $customer = Customer::query()->create($this->customerAttributes());
        app(CreatePaymentRequest::class)->create($customer->id, 1200, 'CDF', 'opaque-conflict-key');

        $this->expectException(InvalidArgumentException::class);
        app(CreatePaymentRequest::class)->create($customer->id, 1199, 'CDF', 'opaque-conflict-key');
    }

    public function test_allocation_delivery_stays_recoverable_when_callback_handoff_fails(): void
    {
        Queue::fake();
        $customer = Customer::query()->create($this->customerAttributes());
        CustomerCredit::query()->create(['customer_id' => $customer->id, 'currency' => 'CDF', 'available_minor' => 1200]);
        $request = app(CreatePaymentRequest::class)->create($customer->id, 1200, 'CDF', 'durable-delivery');
        $delivery = PaymentRequestAllocationDelivery::query()->where('payment_request_id', $request->id)->firstOrFail();

        Event::listen(PaymentRequestAllocated::class, function (): void {
            throw new \RuntimeException('simulated post-handoff crash');
        });
        try {
            app(DispatchPaymentRequestAllocation::class, ['deliveryId' => $delivery->id])->handle();
        } catch (\RuntimeException) {
            // The callback was emitted, but the durable marker stays eligible for replay.
        }
        self::assertNull($delivery->fresh()->dispatched_at);

        Event::fake([PaymentRequestAllocated::class]);
        app(DispatchPaymentRequestAllocation::class, ['deliveryId' => $delivery->id])->handle();
        app(DispatchPaymentRequestAllocation::class, ['deliveryId' => $delivery->id])->handle();

        Event::assertDispatchedTimes(PaymentRequestAllocated::class, 1);
        self::assertNotNull($delivery->fresh()->dispatched_at);
    }

    /** @return array<string, string> */
    private function customerAttributes(): array
    {
        return [
            'organization_id' => '00000000-0000-4000-8000-000000000001',
            'private_lookup_digest' => 'payment-request-fixture',
            'private_lookup_id' => '00000000-0000-4000-8000-000000000010',
            'private_lookup_key_version' => 'v1',
        ];
    }

    /** @return array<string, int|string|CarbonImmutable> */
    private function pendingAttributes(string $customerId, string $id, int $amount, CarbonImmutable $expiresAt, ?CarbonImmutable $createdAt = null): array
    {
        return [
            'id' => $id,
            'customer_id' => $customerId,
            'idempotency_digest' => hash('sha256', $id),
            'currency' => 'CDF',
            'amount_minor' => $amount,
            'remaining_minor' => $amount,
            'status' => PaymentRequestStatus::Pending->value,
            'expires_at' => $expiresAt,
            'created_at' => $createdAt ?? $expiresAt,
            'updated_at' => $createdAt ?? $expiresAt,
        ];
    }

    /** @return array<string, int|string|CarbonImmutable> */
    private function depositAttributes(string $customerId, int $amount): array
    {
        SourceInstallation::query()->find('00000000-0000-4000-8000-000000000020')
            ?? SourceInstallation::query()->forceCreate([
                'id' => '00000000-0000-4000-8000-000000000020',
                'organization_id' => '00000000-0000-4000-8000-000000000001',
                'installation_digest' => 'payment-request-installation-fixture',
                'installation_lookup_id' => '00000000-0000-4000-8000-000000000021',
                'installation_key_version' => 'v1',
            ]);

        return [
            'organization_id' => '00000000-0000-4000-8000-000000000001',
            'customer_id' => $customerId,
            'source_installation_id' => '00000000-0000-4000-8000-000000000020',
            'kind' => 'provider_credit',
            'amount_minor' => $amount,
            'currency' => 'CDF',
            'received_at' => CarbonImmutable::now(),
            'idempotency_digest' => 'payment-request-deposit-fixture',
            'idempotency_key_version' => 'v1',
        ];
    }
}
