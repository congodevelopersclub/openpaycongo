<?php

namespace Tests\Feature;

use App\Deposits\ProviderTransfer;
use App\Deposits\RecordProviderDeposit;
use App\Deposits\RecordResult;
use App\Events\ProviderDepositRecorded;
use App\Models\CustomerCredit;
use App\Models\CustomerCreditPosting;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Event;
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
}
