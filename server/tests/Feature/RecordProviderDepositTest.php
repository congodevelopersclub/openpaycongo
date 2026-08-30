<?php

namespace Tests\Feature;

use App\Deposits\DepositKind;
use App\Deposits\ProviderDepositPreflightMissed;
use App\Deposits\ProviderTransfer;
use App\Deposits\RecordProviderDeposit;
use App\Deposits\RecordResult;
use App\Deposits\ReversalResult;
use App\Models\CustomerCredit;
use App\Models\Deposit;
use App\Models\LedgerEntry;
use App\Models\PrivateLookupAlias;
use App\Models\SourceInstallation;
use App\Models\User;
use App\Reconciliation\ReverseDeposit;
use Illuminate\Database\QueryException;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Event;
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

    public function test_a_new_provider_reference_dispatches_a_pii_free_preflight_marker_only_once(): void
    {
        Event::fake([ProviderDepositPreflightMissed::class]);

        $action = app(RecordProviderDeposit::class);
        $transfer = $this->transfer();
        $action->record($transfer);
        $action->record($transfer);

        Event::assertDispatchedTimes(ProviderDepositPreflightMissed::class, 1);
        Event::assertDispatched(ProviderDepositPreflightMissed::class, static function (ProviderDepositPreflightMissed $event): bool {
            self::assertSame([], get_object_vars($event));

            return true;
        });
    }

    public function test_provider_identity_replays_after_lookup_key_rotation_without_a_second_credit(): void
    {
        config([
            'deposits.lookup_token_key' => 'previous-deposit-lookup-key-material-32',
            'deposits.lookup_token_keys' => ['previous' => 'previous-deposit-lookup-key-material-32'],
            'deposits.lookup_token_active_key_id' => 'previous',
        ]);

        $transfer = $this->transfer();
        $first = app(RecordProviderDeposit::class)->record($transfer);

        config([
            'deposits.lookup_token_key' => 'current-deposit-lookup-key-material-32',
            'deposits.lookup_token_keys' => [
                'current' => 'current-deposit-lookup-key-material-32',
                'previous' => 'previous-deposit-lookup-key-material-32',
            ],
            'deposits.lookup_token_active_key_id' => 'current',
        ]);

        $replay = app(RecordProviderDeposit::class)->record($transfer);

        self::assertSame(RecordResult::Replayed, $replay->outcome);
        self::assertSame($first->deposit->id, $replay->deposit->id);
        self::assertSame('previous', $replay->deposit->provider_reference_key_version);
        self::assertSame('previous', $replay->deposit->idempotency_key_version);
        self::assertDatabaseCount('deposits', 1);
        self::assertDatabaseCount('ledger_entries', 2);
    }

    public function test_numeric_json_lookup_key_ids_are_normalized_to_strings(): void
    {
        config([
            'deposits.lookup_token_keys' => '{"2026":"numeric-lookup-key-material-at-least-32"}',
            'deposits.lookup_token_active_key_id' => '2026',
        ]);

        $result = app(RecordProviderDeposit::class)->record($this->transfer());

        self::assertSame(RecordResult::Recorded, $result->outcome);
        self::assertSame('2026', $result->deposit->provider_reference_key_version);
    }

    public function test_mariadb_deadlock_error_1213_is_retryable(): void
    {
        $previous = new \PDOException('Deadlock found when trying to get lock; try restarting transaction.');
        $previous->errorInfo = ['40001', 1213, 'Deadlock found when trying to get lock; try restarting transaction.'];
        $exception = new QueryException('mariadb', 'insert into private_lookup_aliases', [], $previous);
        $classifier = new \ReflectionMethod(RecordProviderDeposit::class, 'isRetryableTransactionFailure');

        self::assertTrue($classifier->invoke(app(RecordProviderDeposit::class), $exception));
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

        $reversal = app(ReverseDeposit::class);
        $operator = User::factory()->create();
        $operator->is_financial_operator = true;
        $operator->save();
        $first = $reversal->reverse($operator, $deposit, 'provider_correction');
        $replay = $reversal->reverse($operator, $deposit, 'provider_correction');

        self::assertSame(ReversalResult::Reversed, $first->outcome);
        self::assertSame(ReversalResult::Replayed, $replay->outcome);
        self::assertSame($first->deposit->id, $replay->deposit->id);
        self::assertSame($deposit->id, $first->deposit->reverses_deposit_id);
        self::assertDatabaseCount('deposits', 2);
        self::assertDatabaseCount('ledger_entries', 4);
        self::assertSame(0, CustomerCredit::query()->where('customer_id', $deposit->customer_id)->where('currency', 'CDF')->value('available_minor'));
    }

    public function test_a_reversal_uses_the_locked_persisted_deposit_not_a_mutated_model_instance(): void
    {
        $action = app(RecordProviderDeposit::class);
        $deposit = $action->record($this->transfer())->deposit;
        $deposit->amount_minor = 1;
        $deposit->currency = 'USD';
        $deposit->customer_id = Str::uuid()->toString();
        $deposit->source_installation_id = Str::uuid()->toString();

        $operator = User::factory()->create();
        $operator->is_financial_operator = true;
        $operator->save();
        $reversal = app(ReverseDeposit::class)->reverse($operator, $deposit, 'provider_correction')->deposit;

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

    public function test_quiet_and_counter_eloquent_persistence_paths_cannot_mutate_financial_facts(): void
    {
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        $entry = $deposit->ledgerEntries()->firstOrFail();

        $deposit->currency = 'USD';
        $entry->account = 'tampered';
        $this->assertImmutable(static fn (): bool => $deposit->saveQuietly());
        $this->assertImmutable(static fn (): bool => $entry->updateQuietly(['account' => 'tampered']));
        $this->assertImmutable(static fn (): ?bool => $deposit->deleteQuietly());
        $this->assertImmutable(static fn (): ?bool => $entry->deleteQuietly());
        $this->assertImmutable(static fn (): int => $deposit->increment('amount_minor'));
        $this->assertImmutable(static fn (): int => $entry->decrement('credit_minor'));
        $this->assertImmutable(static fn () => $deposit->forceDelete());
        $this->assertImmutable(\Closure::bind(fn () => $this->incrementQuietly('amount_minor'), $deposit, $deposit::class));
        $this->assertImmutable(\Closure::bind(fn () => $this->decrementQuietly('credit_minor'), $entry, $entry::class));
        self::assertDatabaseHas('deposits', ['id' => $deposit->id, 'currency' => 'CDF', 'amount_minor' => 12500]);
        self::assertDatabaseHas('ledger_entries', ['id' => $entry->id, 'account' => 'provider_receivable']);
    }

    public function test_rfc3339_offset_boundaries_are_validated_before_any_write(): void
    {
        foreach (['2026-08-30T01:00:00+23:59', '2026-08-30T01:00:00-23:59'] as $value) {
            self::assertSame(RecordResult::Recorded, app(RecordProviderDeposit::class)->record($this->transfer(providerOccurredAt: $value, providerReference: Str::uuid()->toString()))->outcome);
        }

        foreach (['2026-08-30T01:00:00+24:00', '2026-08-30T01:00:00-24:00', '2026-08-30T01:00:00+23:60'] as $value) {
            $depositsBefore = Deposit::query()->count();
            $ledgerEntriesBefore = LedgerEntry::query()->count();

            try {
                app(RecordProviderDeposit::class)->record($this->transfer(providerOccurredAt: $value, providerReference: Str::uuid()->toString()));
                self::fail('Invalid RFC3339 offsets must be rejected.');
            } catch (InvalidArgumentException) {
                self::assertTrue(true);
            }

            self::assertSame($depositsBefore, Deposit::query()->count());
            self::assertSame($ledgerEntriesBefore, LedgerEntry::query()->count());
        }
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

    public function test_an_invalid_lookup_key_ring_fails_before_any_database_write(): void
    {
        config([
            'deposits.lookup_token_keys' => ['current' => 'too-short'],
            'deposits.lookup_token_active_key_id' => 'current',
        ]);

        $this->expectException(LogicException::class);
        try {
            app(RecordProviderDeposit::class)->record($this->transfer());
        } finally {
            self::assertDatabaseCount('deposits', 0);
        }
    }

    public function test_private_lookup_aliases_are_append_only(): void
    {
        $deposit = app(RecordProviderDeposit::class)->record($this->transfer())->deposit;
        $alias = PrivateLookupAlias::query()->firstOrFail();

        $this->assertImmutable(fn () => $alias->delete());

        self::assertDatabaseHas('private_lookup_aliases', ['id' => $alias->id]);
        self::assertSame($deposit->id, Deposit::query()->firstOrFail()->id);
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

    public function test_financial_table_instants_use_portable_wide_datetime_definitions(): void
    {
        $migration = file_get_contents(database_path('migrations/2026_08_30_000000_create_deposit_ledger_tables.php'));

        self::assertIsString($migration);
        foreach ([
            "\$table->dateTime('provider_occurred_at')->nullable();",
            "\$table->dateTime('received_at');",
            "\$table->dateTime('recorded_at');",
            "\$table->dateTime('created_at')->nullable();",
            "\$table->dateTime('updated_at')->nullable();",
        ] as $declaration) {
            self::assertStringContainsString($declaration, $migration);
        }

        self::assertSame(4, substr_count($migration, 'self::wideTimestamps($table);'));
        self::assertSame(0, preg_match('/\\b(?:timestamp|timestampTz|timestamps|timestampsTz)\\s*\\(/', $migration));
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
