<?php

namespace Tests\Feature;

use App\Deposits\ProviderTransfer;
use App\Deposits\RecordProviderDeposit;
use App\Deposits\RecordResult;
use App\Events\ProviderDepositRecorded;
use App\Jobs\DispatchPaymentRequestAllocation;
use App\Models\CustomerCredit;
use App\Models\CustomerCreditPosting;
use App\Models\PaymentRequestAllocationDelivery;
use App\PaymentRequests\CreatePaymentRequest;
use App\PaymentRequests\PaymentRequestStatus;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Event;
use Illuminate\Support\Facades\Queue;
use Tests\TestCase;

final class MobileDepositCreditWorkflowTest extends TestCase
{
    use RefreshDatabase;

    public function test_committed_mobile_deposit_replay_and_conflict_credit_the_customer_once(): void
    {
        $recordedDepositIds = [];
        Event::listen(ProviderDepositRecorded::class, static function (ProviderDepositRecorded $event) use (&$recordedDepositIds): void {
            $recordedDepositIds[] = $event->depositId;
        });

        $action = app(RecordProviderDeposit::class);
        $transfer = new ProviderTransfer(
            organizationId: '00000000-0000-4000-8000-000000000001',
            installationIdentifier: 'mobile-installation-001',
            customerLookupIdentifier: 'customer-lookup-001',
            providerReference: 'MOBILE-REFERENCE-001',
            amountMinor: 12500,
            currency: 'CDF',
            providerOccurredAt: '2026-08-30T01:00:00Z',
            senderIdentifier: 'MOBILEMONEY',
            receiverIdentifier: null,
        );

        $recorded = $action->record($transfer);
        $replay = $action->record($transfer);
        $conflict = $action->record(new ProviderTransfer(
            organizationId: $transfer->organizationId,
            installationIdentifier: $transfer->installationIdentifier,
            customerLookupIdentifier: $transfer->customerLookupIdentifier,
            providerReference: $transfer->providerReference,
            amountMinor: 12600,
            currency: $transfer->currency,
            providerOccurredAt: $transfer->providerOccurredAt,
            senderIdentifier: $transfer->senderIdentifier,
            receiverIdentifier: $transfer->receiverIdentifier,
        ));

        self::assertSame(RecordResult::Recorded, $recorded->outcome);
        self::assertSame(RecordResult::Replayed, $replay->outcome);
        self::assertSame(RecordResult::Conflict, $conflict->outcome);
        self::assertSame([$recorded->deposit->id], $recordedDepositIds);
        self::assertSame(12500, CustomerCredit::query()->value('available_minor'));
        self::assertSame(1, CustomerCreditPosting::query()->count());
        self::assertSame($recorded->deposit->id, CustomerCreditPosting::query()->value('deposit_id'));
    }

    public function test_rolled_back_mobile_deposit_does_not_dispatch_or_allocate_credit(): void
    {
        Queue::fake([DispatchPaymentRequestAllocation::class]);
        $recordedDepositIds = [];
        Event::listen(ProviderDepositRecorded::class, static function (ProviderDepositRecorded $event) use (&$recordedDepositIds): void {
            $recordedDepositIds[] = $event->depositId;
        });

        DB::beginTransaction();
        app(RecordProviderDeposit::class)->record($this->transfer());
        DB::rollBack();

        self::assertSame([], $recordedDepositIds);
        self::assertDatabaseCount('deposits', 0);
        self::assertDatabaseCount('customer_credits', 0);
        self::assertDatabaseCount('customer_credit_postings', 0);
        self::assertDatabaseCount('payment_request_allocation_deliveries', 0);
        Queue::assertNothingPushed();
    }

    public function test_committed_mobile_deposit_dispatches_after_commit_and_allocates_pending_credit_delivery(): void
    {
        Queue::fake([DispatchPaymentRequestAllocation::class]);
        $recordedDepositIds = [];
        Event::listen(ProviderDepositRecorded::class, static function (ProviderDepositRecorded $event) use (&$recordedDepositIds): void {
            $recordedDepositIds[] = $event->depositId;
        });

        $recorded = null;
        $paymentRequest = null;
        DB::transaction(function () use (&$recorded, &$paymentRequest): void {
            $recorded = app(RecordProviderDeposit::class)->record($this->transfer());
            $paymentRequest = app(CreatePaymentRequest::class)->create(
                $recorded->deposit->customer_id,
                12500,
                'CDF',
                'after-commit-payment-request',
            );

            self::assertSame(PaymentRequestStatus::Pending, $paymentRequest->status);
            self::assertDatabaseCount('customer_credits', 0);
            self::assertDatabaseCount('customer_credit_postings', 0);
            self::assertDatabaseCount('payment_request_allocation_deliveries', 0);
        });

        self::assertNotNull($recorded);
        self::assertNotNull($paymentRequest);
        self::assertSame([$recorded->deposit->id], $recordedDepositIds);
        self::assertSame(0, CustomerCredit::query()->value('available_minor'));
        self::assertSame(12500, CustomerCreditPosting::query()->value('amount_minor'));
        self::assertSame($recorded->deposit->id, CustomerCreditPosting::query()->value('deposit_id'));

        $delivery = PaymentRequestAllocationDelivery::query()->sole();
        self::assertSame($paymentRequest->id, $delivery->payment_request_id);
        Queue::assertPushed(DispatchPaymentRequestAllocation::class, static fn (DispatchPaymentRequestAllocation $job): bool => $job->deliveryId === $delivery->id);
    }

    private function transfer(): ProviderTransfer
    {
        return new ProviderTransfer(
            organizationId: '00000000-0000-4000-8000-000000000001',
            installationIdentifier: 'mobile-installation-001',
            customerLookupIdentifier: 'customer-lookup-001',
            providerReference: 'MOBILE-REFERENCE-001',
            amountMinor: 12500,
            currency: 'CDF',
            providerOccurredAt: '2026-08-30T01:00:00Z',
            senderIdentifier: 'MOBILEMONEY',
            receiverIdentifier: null,
        );
    }
}
