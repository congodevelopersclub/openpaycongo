<?php

namespace Tests\Feature;

use App\Deposits\DepositKind;
use App\Deposits\ProviderTransfer;
use App\Deposits\RecordProviderDeposit;
use App\Deposits\RecordResult;
use App\Deposits\ReversalResult;
use App\Models\Deposit;
use App\Models\LedgerEntry;
use App\Models\SourceInstallation;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use InvalidArgumentException;
use LogicException;
use Tests\TestCase;

final class RecordProviderDepositTest extends TestCase
{
    use RefreshDatabase;

    public function test_it_records_a_provider_transfer_once_with_encrypted_pii_and_balanced_ledger_entries(): void
    {
        $transfer = $this->transfer();
        $result = app(RecordProviderDeposit::class)->record($transfer);

        self::assertSame(RecordResult::Recorded, $result->outcome);
        self::assertSame('CDF', $result->deposit->currency);
        self::assertSame(12500, $result->deposit->amount_minor);
        self::assertSame($transfer->senderIdentifier, $result->deposit->sender_identifier);
        self::assertSame($transfer->receiverIdentifier, $result->deposit->receiver_identifier);
        self::assertNotSame($transfer->senderIdentifier, $result->deposit->getRawOriginal('sender_identifier'));
        self::assertNotSame($transfer->receiverIdentifier, $result->deposit->getRawOriginal('receiver_identifier'));
        self::assertNotSame($transfer->providerReference, $result->deposit->getRawOriginal('provider_reference'));
        self::assertArrayNotHasKey('provider_reference', $result->deposit->toArray());
        self::assertArrayNotHasKey('sender_identifier', $result->deposit->toArray());
        self::assertArrayNotHasKey('receiver_identifier', $result->deposit->toArray());
        self::assertDatabaseCount('customers', 1);
        self::assertDatabaseCount('source_installations', 1);
        self::assertDatabaseCount('ledger_entries', 2);
        self::assertSame(
            LedgerEntry::query()->where('deposit_id', $result->deposit->id)->sum('debit_minor'),
            LedgerEntry::query()->where('deposit_id', $result->deposit->id)->sum('credit_minor'),
        );
    }

    public function test_an_exact_replay_returns_the_original_deposit_without_new_ledger_entries(): void
    {
        $action = app(RecordProviderDeposit::class);
        $transfer = $this->transfer();
        $first = $action->record($transfer);
        $replay = $action->record($transfer);

        self::assertSame(RecordResult::Replayed, $replay->outcome);
        self::assertSame($first->deposit->id, $replay->deposit->id);
        self::assertDatabaseCount('deposits', 1);
        self::assertDatabaseCount('ledger_entries', 2);
    }

    public function test_a_literal_z_provider_timestamp_is_accepted_and_canonicalized_to_utc(): void
    {
        $result = app(RecordProviderDeposit::class)->record($this->transfer(
            providerOccurredAt: '2026-08-30T01:00:00Z',
        ));

        self::assertSame(RecordResult::Recorded, $result->outcome);
        self::assertSame('2026-08-30T01:00:00+00:00', $result->deposit->provider_occurred_at?->toAtomString());
    }

    public function test_a_non_zero_offset_provider_timestamp_is_persisted_as_its_utc_instant(): void
    {
        $result = app(RecordProviderDeposit::class)->record($this->transfer(
            providerOccurredAt: '2026-08-30T03:00:00+02:00',
        ));

        self::assertSame('2026-08-30T01:00:00+00:00', $result->deposit->provider_occurred_at?->toAtomString());
        self::assertSame(
            '2026-08-30 01:00:00',
            DB::table('deposits')->where('id', $result->deposit->id)->value('provider_occurred_at'),
        );
    }

    public function test_equivalent_offset_and_utc_provider_timestamps_are_an_exact_replay(): void
    {
        $action = app(RecordProviderDeposit::class);
        $offsetTransfer = $this->transfer(providerOccurredAt: '2026-08-30T03:00:00+02:00');
        $first = $action->record($offsetTransfer);
        $utcTransfer = new ProviderTransfer(
            organizationId: $offsetTransfer->organizationId,
            installationIdentifier: $offsetTransfer->installationIdentifier,
            customerLookupIdentifier: $offsetTransfer->customerLookupIdentifier,
            providerReference: $offsetTransfer->providerReference,
            amountMinor: $offsetTransfer->amountMinor,
            currency: $offsetTransfer->currency,
            providerOccurredAt: '2026-08-30T01:00:00+00:00',
            senderIdentifier: $offsetTransfer->senderIdentifier,
            receiverIdentifier: $offsetTransfer->receiverIdentifier,
        );

        $replay = $action->record($utcTransfer);

        self::assertSame(RecordResult::Replayed, $replay->outcome);
        self::assertTrue($first->deposit->is($replay->deposit));
    }

    public function test_a_conflicting_replay_is_deterministically_rejected(): void
    {
        $action = app(RecordProviderDeposit::class);
        $action->record($this->transfer());
        $conflict = $action->record($this->transfer(amountMinor: 12600));

        self::assertSame(RecordResult::Conflict, $conflict->outcome);
        self::assertDatabaseCount('deposits', 1);
        self::assertDatabaseCount('ledger_entries', 2);
    }

    public function test_multiple_installations_can_credit_the_same_organization_wide_customer(): void
    {
        $action = app(RecordProviderDeposit::class);
        $firstTransfer = $this->transfer();
        $first = $action->record($firstTransfer);
        $second = $action->record($this->transfer(
            installation: 'installation-002',
            providerReference: 'provider-002',
            customerLookup: $firstTransfer->customerLookupIdentifier,
        ));

        self::assertSame($first->deposit->customer_id, $second->deposit->customer_id);
        self::assertDatabaseCount('customers', 1);
        self::assertDatabaseCount('source_installations', 2);
        self::assertDatabaseCount('deposits', 2);
        self::assertDatabaseCount('ledger_entries', 4);
    }

    public function test_a_reversal_appends_balanced_immutable_entries_and_exactly_replays(): void
    {
        $action = app(RecordProviderDeposit::class);
        $deposit = $action->record($this->transfer())->deposit;

        $first = $action->reverse($deposit);
        $replay = $action->reverse($deposit);

        self::assertSame(ReversalResult::Reversed, $first->outcome);
        self::assertSame(ReversalResult::Replayed, $replay->outcome);
        self::assertSame($first->deposit->id, $replay->deposit->id);
        self::assertSame($deposit->id, $first->deposit->reverses_deposit_id);
        self::assertDatabaseCount('deposits', 2);
        self::assertDatabaseCount('ledger_entries', 4);
    }

    public function test_a_reversal_uses_the_locked_persisted_deposit_not_a_mutated_model_instance(): void
    {
        $action = app(RecordProviderDeposit::class);
        $deposit = $action->record($this->transfer())->deposit;
        $deposit->amount_minor = 1;
        $deposit->currency = 'USD';
        $deposit->customer_id = Str::uuid()->toString();
        $deposit->source_installation_id = Str::uuid()->toString();

        $reversal = $action->reverse($deposit)->deposit;

        self::assertSame(12500, $reversal->amount_minor);
        self::assertSame('CDF', $reversal->currency);
        self::assertSame(Deposit::query()->findOrFail($deposit->id)->customer_id, $reversal->customer_id);
        self::assertSame(Deposit::query()->findOrFail($deposit->id)->source_installation_id, $reversal->source_installation_id);
    }

    public function test_persisted_deposits_and_ledger_entries_cannot_be_updated_or_deleted(): void
    {
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        $entry = $deposit->ledgerEntries()->firstOrFail();

        $deposit->currency = 'USD';
        $this->assertImmutable(static fn (): bool => $deposit->save());
        $this->assertImmutable(static fn (): bool => $deposit->delete());
        $entry->account = 'tampered';
        $this->assertImmutable(static fn (): bool => $entry->save());
        $this->assertImmutable(static fn (): bool => $entry->delete());
        self::assertDatabaseHas('deposits', ['id' => $deposit->id, 'currency' => 'CDF']);
        self::assertDatabaseHas('ledger_entries', ['id' => $entry->id, 'account' => 'provider_receivable']);
    }

    public function test_control_characters_are_rejected_before_they_can_make_an_ambiguous_idempotency_payload(): void
    {
        $transfer = $this->transfer(providerReference: "provider\nreference");

        $this->expectException(InvalidArgumentException::class);
        app(RecordProviderDeposit::class)->record($transfer);
    }

    public function test_an_unconfigured_lookup_token_key_fails_before_any_database_write(): void
    {
        config(['deposits.lookup_token_key' => '']);

        $this->expectException(LogicException::class);
        try {
            app(RecordProviderDeposit::class)->record($this->transfer());
        } finally {
            self::assertDatabaseCount('deposits', 0);
            config(['deposits.lookup_token_key' => 'testing-deposit-lookup-key-material-32']);
        }
    }

    public function test_an_unsupported_currency_is_rejected_before_any_database_write(): void
    {
        $transfer = new ProviderTransfer(
            organizationId: '00000000-0000-4000-8000-000000000001',
            installationIdentifier: 'installation-001',
            customerLookupIdentifier: Str::uuid()->toString(),
            providerReference: 'provider-001',
            amountMinor: 12500,
            currency: 'USD',
            providerOccurredAt: '2026-08-30T01:00:00+00:00',
            senderIdentifier: Str::uuid()->toString(),
            receiverIdentifier: Str::uuid()->toString(),
        );

        $this->expectException(InvalidArgumentException::class);
        try {
            app(RecordProviderDeposit::class)->record($transfer);
        } finally {
            self::assertDatabaseCount('deposits', 0);
        }
    }

    public function test_every_deposit_kind_fits_the_declared_portable_storage_length(): void
    {
        $migration = require database_path('migrations/2026_08_30_000000_create_deposit_ledger_tables.php');
        $storageLength = (new \ReflectionClass($migration))->getReflectionConstant('DEPOSIT_KIND_LENGTH')?->getValue();

        self::assertIsInt($storageLength);
        foreach (DepositKind::cases() as $kind) {
            self::assertLessThanOrEqual($storageLength, mb_strlen($kind->value));
        }
    }

    public function test_provider_occurrence_uses_portable_wide_datetime_storage(): void
    {
        $migration = file_get_contents(database_path('migrations/2026_08_30_000000_create_deposit_ledger_tables.php'));

        self::assertIsString($migration);
        self::assertStringContainsString("\$table->dateTime('provider_occurred_at')->nullable();", $migration);
        self::assertStringNotContainsString("timestampTz('provider_occurred_at')", $migration);

        $result = app(RecordProviderDeposit::class)->record($this->transfer(
            providerOccurredAt: '2040-01-01T00:00:00Z',
        ));

        self::assertSame('2040-01-01 00:00:00', DB::table('deposits')->where('id', $result->deposit->id)->value('provider_occurred_at'));
    }

    public function test_provider_occurrence_that_normalizes_before_year_1000_is_rejected_before_writes(): void
    {
        $this->expectException(InvalidArgumentException::class);
        try {
            app(RecordProviderDeposit::class)->record($this->transfer(
                providerOccurredAt: '1000-01-01T00:00:00+01:00',
            ));
        } finally {
            self::assertDatabaseCount('deposits', 0);
        }
    }

    public function test_provider_occurrence_that_normalizes_after_year_9999_is_rejected_before_writes(): void
    {
        $this->expectException(InvalidArgumentException::class);
        try {
            app(RecordProviderDeposit::class)->record($this->transfer(
                providerOccurredAt: '9999-12-31T23:59:59-01:00',
            ));
        } finally {
            self::assertDatabaseCount('deposits', 0);
        }
    }

    public function test_private_digests_are_separated_by_purpose_and_organization(): void
    {
        $action = app(RecordProviderDeposit::class);
        $identifier = Str::uuid()->toString();
        $firstTransfer = $this->transfer(
            installation: $identifier,
            providerReference: $identifier,
            customerLookup: $identifier,
        );
        $first = $action->record($firstTransfer);
        $second = $action->record($this->transfer(
            installation: $identifier,
            providerReference: $identifier,
            customerLookup: $identifier,
            organizationId: '00000000-0000-4000-8000-000000000002',
        ));
        $firstInstallation = SourceInstallation::query()->where('organization_id', $first->deposit->organization_id)->firstOrFail();
        $secondInstallation = SourceInstallation::query()->where('organization_id', $second->deposit->organization_id)->firstOrFail();

        self::assertNotSame($first->deposit->provider_reference_digest, $first->deposit->customer->private_lookup_digest);
        self::assertNotSame($first->deposit->provider_reference_digest, $firstInstallation->installation_digest);
        self::assertNotSame($first->deposit->customer->private_lookup_digest, $firstInstallation->installation_digest);
        self::assertNotSame($first->deposit->provider_reference_digest, $second->deposit->provider_reference_digest);
        self::assertNotSame($first->deposit->customer->private_lookup_digest, $second->deposit->customer->private_lookup_digest);
        self::assertNotSame($firstInstallation->installation_digest, $secondInstallation->installation_digest);
    }

    public function test_an_unsupported_lookup_token_version_setting_does_not_change_exact_replay(): void
    {
        $action = app(RecordProviderDeposit::class);
        $transfer = $this->transfer();

        $first = $action->record($transfer);

        config(['deposits.lookup_token_key_version' => 'unsupported-v999']);

        $replay = $action->record($transfer);

        self::assertSame(RecordResult::Replayed, $replay->outcome);
        self::assertTrue($first->deposit->is($replay->deposit));
    }

    private function transfer(
        int $amountMinor = 12500,
        string $installation = 'installation-001',
        string $providerReference = 'provider-001',
        ?string $customerLookup = null,
        string $organizationId = '00000000-0000-4000-8000-000000000001',
        string $providerOccurredAt = '2026-08-30T01:00:00+00:00',
    ): ProviderTransfer {
        return new ProviderTransfer(
            organizationId: $organizationId,
            installationIdentifier: $installation,
            customerLookupIdentifier: $customerLookup ?? Str::uuid()->toString(),
            providerReference: $providerReference,
            amountMinor: $amountMinor,
            currency: 'CDF',
            providerOccurredAt: $providerOccurredAt,
            senderIdentifier: Str::uuid()->toString(),
            receiverIdentifier: Str::uuid()->toString(),
        );
    }

    private function assertImmutable(\Closure $attempt): void
    {
        try {
            $attempt();
            self::fail('Persisted ledger records must be immutable.');
        } catch (LogicException) {
            self::assertTrue(true);
        }
    }
}
