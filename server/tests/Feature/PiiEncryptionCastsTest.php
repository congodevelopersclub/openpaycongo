<?php

namespace Tests\Feature;

use App\Deposits\ProviderTransfer;
use App\Deposits\RecordProviderDeposit;
use App\Models\Customer;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use InvalidArgumentException;
use Tests\TestCase;

final class PiiEncryptionCastsTest extends TestCase
{
    use RefreshDatabase;

    public function test_customer_and_provider_pii_are_encrypted_at_rest_hidden_and_transparently_read(): void
    {
        $transfer = new ProviderTransfer(
            organizationId: '00000000-0000-4000-8000-000000000169',
            installationIdentifier: 'test-installation-169',
            customerLookupIdentifier: 'test-customer-lookup-169',
            providerReference: 'test-provider-reference-169',
            amountMinor: 12500,
            currency: 'CDF',
            providerOccurredAt: '2026-08-31T00:00:00Z',
            senderIdentifier: 'test-provider-sender-169',
            receiverIdentifier: 'test-provider-receiver-169',
            customerName: 'test-customer-name-169',
            customerAddress: 'test-customer-address-169',
            customerPhone: 'test-customer-phone-169',
            customerEmail: 'test-customer-email-169',
        );

        $deposit = app(RecordProviderDeposit::class)->record($transfer)->deposit;
        $customer = $deposit->customer->fresh();

        self::assertSame($transfer->customerName, $customer->name);
        self::assertSame($transfer->customerAddress, $customer->address);
        self::assertSame($transfer->customerPhone, $customer->phone);
        self::assertSame($transfer->customerEmail, $customer->email);
        self::assertSame($transfer->providerReference, $deposit->fresh()->provider_reference);
        self::assertSame($transfer->senderIdentifier, $deposit->fresh()->sender_identifier);
        self::assertSame($transfer->receiverIdentifier, $deposit->fresh()->receiver_identifier);

        $rawCustomer = DB::table('customers')->where('id', $customer->id)->first();
        foreach (['name', 'address', 'phone', 'email'] as $attribute) {
            self::assertNotSame($customer->{$attribute}, $rawCustomer->{$attribute});
            self::assertStringNotContainsString($customer->{$attribute}, $rawCustomer->{$attribute});
            self::assertArrayNotHasKey($attribute, $customer->toArray());
        }
        foreach (['provider_reference', 'sender_identifier', 'receiver_identifier'] as $attribute) {
            self::assertArrayNotHasKey($attribute, $deposit->toArray());
        }
    }

    public function test_laravel_previous_key_decrypts_existing_customer_pii_before_controlled_reencryption(): void
    {
        $previousKey = 'base64:QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE=';
        $currentKey = 'base64:QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI=';
        config(['app.key' => $previousKey, 'app.previous_keys' => []]);
        app()->forgetInstance('encrypter');

        $customer = Customer::query()->create([
            'organization_id' => '00000000-0000-4000-8000-000000000169',
            'private_lookup_digest' => str_repeat('a', 64),
            'name' => 'test-rotated-name-169',
        ]);
        $ciphertext = $customer->getRawOriginal('name');

        config(['app.key' => $currentKey, 'app.previous_keys' => [$previousKey]]);
        app()->forgetInstance('encrypter');

        $rotated = Customer::query()->findOrFail($customer->id);

        self::assertSame('test-rotated-name-169', $rotated->name);
        self::assertSame($ciphertext, $rotated->getRawOriginal('name'));
        self::assertArrayNotHasKey('name', $rotated->toArray());
    }

    public function test_customer_pii_is_bounded_before_any_write(): void
    {
        $transfer = new ProviderTransfer(
            organizationId: '00000000-0000-4000-8000-000000000169',
            installationIdentifier: 'test-installation-169',
            customerLookupIdentifier: 'test-customer-lookup-169',
            providerReference: 'test-provider-reference-169',
            amountMinor: 12500,
            currency: 'CDF',
            providerOccurredAt: '2026-08-31T00:00:00Z',
            senderIdentifier: null,
            receiverIdentifier: null,
            customerEmail: str_repeat('x', 321),
        );

        $this->expectException(InvalidArgumentException::class);

        try {
            app(RecordProviderDeposit::class)->record($transfer);
        } finally {
            self::assertDatabaseCount('customers', 0);
            self::assertDatabaseCount('deposits', 0);
        }
    }

    public function test_existing_customer_receives_supplied_pii_without_erasing_omitted_values(): void
    {
        $action = app(RecordProviderDeposit::class);
        $organizationId = '00000000-0000-4000-8000-000000000169';

        $first = $action->record(new ProviderTransfer(
            organizationId: $organizationId,
            installationIdentifier: 'test-installation-169',
            customerLookupIdentifier: 'test-existing-customer-169',
            providerReference: 'test-existing-customer-first-169',
            amountMinor: 12500,
            currency: 'CDF',
            providerOccurredAt: '2026-08-31T00:00:00Z',
            senderIdentifier: null,
            receiverIdentifier: null,
        ));
        $updated = $action->record(new ProviderTransfer(
            organizationId: $organizationId,
            installationIdentifier: 'test-installation-169',
            customerLookupIdentifier: 'test-existing-customer-169',
            providerReference: 'test-existing-customer-second-169',
            amountMinor: 12500,
            currency: 'CDF',
            providerOccurredAt: '2026-08-31T00:00:00Z',
            senderIdentifier: null,
            receiverIdentifier: null,
            customerName: 'test-existing-customer-name-169',
            customerEmail: 'test-existing-customer-email-169',
        ));
        $preserved = $action->record(new ProviderTransfer(
            organizationId: $organizationId,
            installationIdentifier: 'test-installation-169',
            customerLookupIdentifier: 'test-existing-customer-169',
            providerReference: 'test-existing-customer-third-169',
            amountMinor: 12500,
            currency: 'CDF',
            providerOccurredAt: '2026-08-31T00:00:00Z',
            senderIdentifier: null,
            receiverIdentifier: null,
        ));

        $customer = $preserved->deposit->customer->fresh();

        self::assertSame($first->deposit->customer_id, $updated->deposit->customer_id);
        self::assertSame($updated->deposit->customer_id, $preserved->deposit->customer_id);
        self::assertSame('test-existing-customer-name-169', $customer->name);
        self::assertSame('test-existing-customer-email-169', $customer->email);
        self::assertArrayNotHasKey('name', $customer->toArray());
        self::assertArrayNotHasKey('email', $customer->toArray());
        self::assertStringNotContainsString('test-existing-customer-name-169', (string) $customer->getRawOriginal('name'));
        self::assertStringNotContainsString('test-existing-customer-email-169', (string) $customer->getRawOriginal('email'));
    }
}
