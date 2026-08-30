<?php

namespace Tests\Feature;

use App\Deposits\ProviderTransfer;
use App\Deposits\RecordProviderDeposit;
use App\Deposits\RecordResult;
use Illuminate\Foundation\Testing\DatabaseMigrations;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use Tests\TestCase;

final class LookupKeyVersionMigrationTest extends TestCase
{
    use DatabaseMigrations;

    public function test_upgrade_backfills_pr180_private_digests_and_rotated_reads_keep_the_same_facts(): void
    {
        $organizationId = '00000000-0000-4000-8000-000000000165';
        $customerIdentifier = 'legacy-customer';
        $installationIdentifier = 'legacy-installation';
        $providerReference = 'legacy-provider-reference';
        $previousKey = 'previous-deposit-lookup-key-material-32';
        $occurredAt = '2026-08-30T01:00:00+00:00';
        $customerId = (string) Str::uuid();
        $installationId = (string) Str::uuid();
        $depositId = (string) Str::uuid();

        $this->artisan('migrate:rollback', ['--step' => 1])->assertExitCode(0);

        DB::table('customers')->insert([
            'id' => $customerId,
            'organization_id' => $organizationId,
            'private_lookup_digest' => $this->digest('customer_lookup', $organizationId, $customerIdentifier, $previousKey),
            'created_at' => now(),
            'updated_at' => now(),
        ]);
        DB::table('source_installations')->insert([
            'id' => $installationId,
            'organization_id' => $organizationId,
            'installation_digest' => $this->digest('installation_lookup', $organizationId, $installationIdentifier, $previousKey),
            'created_at' => now(),
            'updated_at' => now(),
        ]);
        DB::table('deposits')->insert([
            'id' => $depositId,
            'organization_id' => $organizationId,
            'customer_id' => $customerId,
            'source_installation_id' => $installationId,
            'kind' => 'provider_credit',
            'amount_minor' => 12500,
            'currency' => 'CDF',
            'provider_reference' => 'legacy encrypted reference',
            'provider_reference_digest' => $this->digest('provider_reference', $organizationId, $providerReference, $previousKey),
            'provider_occurred_at' => $occurredAt,
            'received_at' => now(),
            'idempotency_digest' => $this->idempotencyDigest($organizationId, $installationIdentifier, $customerIdentifier, $providerReference, $occurredAt, $previousKey),
            'created_at' => now(),
            'updated_at' => now(),
        ]);
        DB::table('ledger_entries')->insert([
            ['id' => (string) Str::uuid(), 'deposit_id' => $depositId, 'organization_id' => $organizationId, 'account' => 'provider_receivable', 'debit_minor' => 12500, 'credit_minor' => 0, 'currency' => 'CDF', 'recorded_at' => now(), 'created_at' => now(), 'updated_at' => now()],
            ['id' => (string) Str::uuid(), 'deposit_id' => $depositId, 'organization_id' => $organizationId, 'account' => 'customer_credit', 'debit_minor' => 0, 'credit_minor' => 12500, 'currency' => 'CDF', 'recorded_at' => now(), 'created_at' => now(), 'updated_at' => now()],
        ]);

        $this->artisan('migrate', ['--force' => true])->assertExitCode(0);

        foreach ([
            ['customers', 'private_lookup_id', 'customer_lookup', $this->digest('customer_lookup', $organizationId, $customerIdentifier, $previousKey)],
            ['source_installations', 'installation_lookup_id', 'installation_lookup', $this->digest('installation_lookup', $organizationId, $installationIdentifier, $previousKey)],
            ['deposits', 'provider_reference_lookup_id', 'provider_reference', $this->digest('provider_reference', $organizationId, $providerReference, $previousKey)],
        ] as [$table, $lookupIdColumn, $purpose, $digest]) {
            $lookupId = DB::table($table)->value($lookupIdColumn);
            self::assertNotNull($lookupId);
            self::assertDatabaseHas('private_lookup_aliases', [
                'organization_id' => $organizationId,
                'purpose' => $purpose,
                'digest' => $digest,
                'lookup_id' => $lookupId,
            ]);
        }

        config([
            'deposits.lookup_token_keys' => [
                'current' => 'current-deposit-lookup-key-material-32',
                'previous' => $previousKey,
            ],
            'deposits.lookup_token_active_key_id' => 'current',
        ]);

        $action = app(RecordProviderDeposit::class);
        $legacy = new ProviderTransfer($organizationId, $installationIdentifier, $customerIdentifier, $providerReference, 12500, 'CDF', '2026-08-30T01:00:00Z', null, null);
        $replay = $action->record($legacy);
        $newProviderReference = 'rotated-provider-reference';
        $recorded = $action->record(new ProviderTransfer($organizationId, $installationIdentifier, $customerIdentifier, $newProviderReference, 12500, 'CDF', '2026-08-30T01:00:00Z', null, null));

        self::assertSame(RecordResult::Replayed, $replay->outcome);
        self::assertSame($depositId, $replay->deposit->id);
        self::assertSame(RecordResult::Recorded, $recorded->outcome);
        self::assertSame($customerId, $recorded->deposit->customer_id);
        self::assertSame($installationId, $recorded->deposit->source_installation_id);
        self::assertDatabaseCount('customers', 1);
        self::assertDatabaseCount('source_installations', 1);
        self::assertDatabaseCount('deposits', 2);
        self::assertSame(12500, DB::table('ledger_entries')->where('deposit_id', $depositId)->sum('credit_minor'));
        self::assertSame(2, DB::table('ledger_entries')->where('deposit_id', $depositId)->count());
        self::assertDatabaseCount('private_lookup_aliases', 7);
    }

    private function digest(string $purpose, string $organizationId, string $value, string $key): string
    {
        return hash_hmac('sha256', json_encode([
            'version' => 'openpay.lookup.v1',
            'purpose' => $purpose,
            'organization_id' => $organizationId,
            'value' => $value,
        ], JSON_THROW_ON_ERROR), $key);
    }

    private function idempotencyDigest(string $organizationId, string $installationIdentifier, string $customerIdentifier, string $providerReference, string $occurredAt, string $key): string
    {
        return $this->digest('idempotency', $organizationId, json_encode([
            'organization_id' => $organizationId,
            'installation_identifier' => $installationIdentifier,
            'customer_lookup_identifier' => $customerIdentifier,
            'provider_reference' => $providerReference,
            'amount_minor' => 12500,
            'currency' => 'CDF',
            'provider_occurred_at' => $occurredAt,
            'sender_identifier' => null,
            'receiver_identifier' => null,
        ], JSON_THROW_ON_ERROR), $key);
    }
}
