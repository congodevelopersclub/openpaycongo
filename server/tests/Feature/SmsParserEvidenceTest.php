<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\Deposits\MobileDepositInput;
use App\Deposits\RecordProviderDeposit;
use App\Deposits\RecordResult;
use App\Deposits\SubmitMobileDeposit;
use App\Models\ApprovedSmsParserRelease;
use App\Models\Deposit;
use App\Models\SourceInstallation;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Validation\ValidationException;
use Tests\TestCase;

final class SmsParserEvidenceTest extends TestCase
{
    use RefreshDatabase;

    public function test_parser_evidence_is_required_for_the_sms_path_and_unknown_fields_are_rejected(): void
    {
        $payload = $this->depositPayload();

        try {
            MobileDepositInput::validate($payload, requireParserEvidence: true);
            self::fail('The SMS path accepted a deposit without parser evidence.');
        } catch (ValidationException) {
            self::assertTrue(true);
        }

        self::assertSame($payload, MobileDepositInput::validate($payload));
        $payload['parser_evidence'] = [...$this->evidence(), 'raw_sms' => 'must not be accepted'];

        try {
            MobileDepositInput::validate($payload);
            self::fail('Parser evidence accepted an unknown property.');
        } catch (ValidationException) {
            self::assertTrue(true);
        }
    }

    public function test_only_current_registered_release_can_attach_encrypted_provisional_evidence_and_it_is_idempotent(): void
    {
        $installation = $this->installation();
        $payload = [...$this->depositPayload(), 'parser_evidence' => $this->evidence()];
        $submit = app(SubmitMobileDeposit::class);

        try {
            $submit->submit($installation, $payload, requireParserEvidence: true);
            self::fail('An unpublished parser release was accepted.');
        } catch (ValidationException) {
            self::assertDatabaseCount('deposits', 0);
        }

        $this->approveRelease();
        $registered = app(RecordProviderDeposit::class)->registerCustomer($installation->organization_id, $payload['customer_lookup_identifier']);
        $first = $submit->submit($installation, $payload, requireParserEvidence: true);
        $replay = $submit->submit($installation, $payload, requireParserEvidence: true);

        self::assertSame(RecordResult::Recorded, $first->outcome);
        self::assertSame(RecordResult::Replayed, $replay->outcome);
        self::assertSame($registered->id, $first->deposit->customer_id);
        self::assertSame($payload['parser_evidence'], $first->deposit->parser_evidence);
        self::assertNotSame(json_encode($payload['parser_evidence']), $first->deposit->getRawOriginal('parser_evidence'));
        self::assertArrayNotHasKey('parser_evidence', $first->deposit->toArray());

        $reordered = $payload;
        $reordered['parser_evidence'] = array_reverse($payload['parser_evidence'], preserve_keys: true);
        self::assertSame(RecordResult::Replayed, $submit->submit($installation, $reordered, true)->outcome);

        $redelivery = $payload;
        $redelivery['parser_evidence']['sms_received_at'] = CarbonImmutable::parse($payload['parser_evidence']['sms_received_at'])
            ->addSecond()->format('Y-m-d\\TH:i:s\\Z');
        self::assertSame(RecordResult::Replayed, $submit->submit($installation, $redelivery, true)->outcome);
        self::assertSame($payload['parser_evidence'], Deposit::query()->sole()->parser_evidence);
        self::assertDatabaseCount('deposits', 1);
    }

    public function test_publisher_emits_the_pinned_signed_release_bundle_and_registers_it(): void
    {
        $seed = str_repeat('s', SODIUM_CRYPTO_SIGN_SEEDBYTES);
        $encodedSeed = $this->base64Url($seed);
        config(['openpay.pairing.enrollment_signing_secret' => $encodedSeed]);
        $template = 'Received {amount} {currency}; ref {reference}; customer {customer}; at {occurred_at}';

        $exitCode = Artisan::call('sms-parser:publish', [
            'provider' => 'OPERATOR_A',
            'sender' => '12345',
            'template' => $template,
            'pattern_version' => '3',
            'expires_at' => '2027-01-01T00:00:00Z',
        ]);
        $bundle = json_decode(Artisan::output(), true, 16, JSON_THROW_ON_ERROR);
        $release = $bundle['release'];
        $transcript = $this->transcript($release);
        $publicKey = $this->decodeBase64Url($bundle['signing_public_key']);
        $signature = $this->decodeBase64Url($release['signature']);

        self::assertSame(0, $exitCode);
        self::assertSame(32, strlen($publicKey));
        self::assertSame(64, strlen($signature));
        self::assertTrue(sodium_crypto_sign_verify_detached($signature, $transcript, $publicKey));
        self::assertSame(hash('sha256', $transcript), ApprovedSmsParserRelease::query()->sole()->release_id);
        self::assertSame($this->base64Url($publicKey), ApprovedSmsParserRelease::query()->sole()->signing_public_key);
        self::assertStringNotContainsString($encodedSeed, Artisan::output());

        self::assertSame(1, Artisan::call('sms-parser:publish', [
            'provider' => 'OPERATOR_A',
            'sender' => '12345',
            'template' => $template,
            'pattern_version' => '3',
            'expires_at' => '2027-01-01T00:00:00Z',
        ]));
        self::assertSame(1, ApprovedSmsParserRelease::query()->count());

        self::assertSame(0, Artisan::call('sms-parser:publish', [
            'provider' => 'OPERATOR_A',
            'sender' => '12345',
            'template' => $template,
            'pattern_version' => '4',
            'expires_at' => '2027-01-01T00:00:00Z',
        ]));
        self::assertSame(2, ApprovedSmsParserRelease::query()->count());
    }

    public function test_publisher_refuses_noncanonical_provider_and_sender_identities(): void
    {
        config(['openpay.pairing.enrollment_signing_secret' => $this->base64Url(str_repeat('s', SODIUM_CRYPTO_SIGN_SEEDBYTES))]);
        $template = 'Received {amount} {currency}; ref {reference}; customer {customer}; at {occurred_at}';

        self::assertSame(1, Artisan::call('sms-parser:publish', [
            'provider' => 'operator_a',
            'sender' => '12345',
            'template' => $template,
            'pattern_version' => '1',
            'expires_at' => '2027-01-01T00:00:00Z',
        ]));
        self::assertSame(1, Artisan::call('sms-parser:publish', [
            'provider' => 'OPERATOR_A',
            'sender' => 'payout',
            'template' => $template,
            'pattern_version' => '1',
            'expires_at' => '2027-01-01T00:00:00Z',
        ]));
        self::assertSame(0, ApprovedSmsParserRelease::query()->count());
    }

    public function test_validly_captured_sms_can_be_submitted_and_retried_after_release_expiry(): void
    {
        $now = CarbonImmutable::now('UTC')->startOfSecond();
        $capturedAt = $now->subSecond();
        $expiresAt = $now->addSeconds(2);
        $this->approveRelease($now->subMinute()->format('Y-m-d\\TH:i:s\\Z'), $expiresAt->format('Y-m-d\\TH:i:s\\Z'));
        $payload = [...$this->depositPayload(), 'parser_evidence' => $this->evidence($capturedAt->format('Y-m-d\\TH:i:s\\Z'))];
        $installation = $this->installation();

        $this->travelTo($now->addSeconds(4));
        $first = app(SubmitMobileDeposit::class)->submit($installation, $payload, requireParserEvidence: true);
        $retry = app(SubmitMobileDeposit::class)->submit($installation, $payload, requireParserEvidence: true);

        self::assertSame(RecordResult::Recorded, $first->outcome);
        self::assertSame(RecordResult::Replayed, $retry->outcome);
    }

    public function test_sms_capture_outside_release_window_or_too_far_in_the_future_is_rejected(): void
    {
        $now = CarbonImmutable::now('UTC')->startOfSecond();
        $this->approveRelease(
            $now->subMinute()->format('Y-m-d\\TH:i:s\\Z'),
            $now->subSeconds(30)->format('Y-m-d\\TH:i:s\\Z'),
        );
        $installation = $this->installation();
        $payload = [...$this->depositPayload(), 'parser_evidence' => $this->evidence($now->subSeconds(20)->format('Y-m-d\\TH:i:s\\Z'))];

        try {
            app(SubmitMobileDeposit::class)->submit($installation, $payload, true);
            self::fail('A capture outside the signed release time window was accepted.');
        } catch (ValidationException) {
            self::assertDatabaseCount('deposits', 0);
        }

        ApprovedSmsParserRelease::query()->where('release_id', str_repeat('c', 64))->update([
            'expires_at' => $now->addHour()->format('Y-m-d\\TH:i:s\\Z'),
        ]);
        $payload['provider_reference'] = 'sms-reference-future';
        $payload['parser_evidence']['sms_received_at'] = $now->addMinutes(6)->format('Y-m-d\\TH:i:s\\Z');
        try {
            app(SubmitMobileDeposit::class)->submit($installation, $payload, true);
            self::fail('A future-dated SMS capture was accepted.');
        } catch (ValidationException) {
            self::assertDatabaseCount('deposits', 0);
        }

        $payload['provider_reference'] = 'sms-reference-sender-mismatch';
        $payload['parser_evidence']['sms_received_at'] = $now->format('Y-m-d\\TH:i:s\\Z');
        $payload['sender_identifier'] = 'OTHER-SENDER';
        try {
            app(SubmitMobileDeposit::class)->submit($installation, $payload, true);
            self::fail('A transaction sender that disagrees with the trusted SMS sender was accepted.');
        } catch (ValidationException) {
            self::assertDatabaseCount('deposits', 0);
        }
    }

    /** @return array<string, mixed> */
    private function depositPayload(): array
    {
        return [
            'customer_lookup_identifier' => 'customer-001',
            'provider_reference' => 'sms-reference-001',
            'amount_minor' => 12500,
            'currency' => 'CDF',
            'provider_occurred_at' => '2026-10-01T01:00:00Z',
            'sender_identifier' => '12345',
        ];
    }

    /** @return array<string, mixed> */
    private function evidence(?string $smsReceivedAt = null): array
    {
        return [
            'kind' => 'signed_release',
            'provider' => 'OPERATOR_A',
            'sms_sender' => '12345',
            'parser_version' => 3,
            'sms_received_at' => $smsReceivedAt ?? CarbonImmutable::now('UTC')->startOfSecond()->format('Y-m-d\\TH:i:s\\Z'),
            'evidence_digest' => str_repeat('a', 64),
            'parser_release_id' => str_repeat('c', 64),
        ];
    }

    private function installation(): SourceInstallation
    {
        return SourceInstallation::query()->create([
            'organization_id' => '00000000-0000-4000-8000-000000000001',
            'installation_digest' => str_repeat('a', 64),
        ]);
    }

    private function approveRelease(?string $approvedAt = null, ?string $expiresAt = null): void
    {
        ApprovedSmsParserRelease::query()->create([
            'release_id' => str_repeat('c', 64),
            'provider' => 'OPERATOR_A',
            'sender' => '12345',
            'template' => 'Received {amount} {currency}; ref {reference}; customer {customer}; at {occurred_at}',
            'pattern_version' => 3,
            'approved_at' => $approvedAt ?? now('UTC')->subMinute()->startOfSecond(),
            'expires_at' => $expiresAt ?? now('UTC')->addDay()->startOfSecond(),
            'signature' => $this->base64Url(str_repeat('s', SODIUM_CRYPTO_SIGN_BYTES)),
            'signing_public_key' => $this->base64Url(str_repeat('p', SODIUM_CRYPTO_SIGN_PUBLICKEYBYTES)),
        ]);
    }

    /** @param array<string, mixed> $release */
    private function transcript(array $release): string
    {
        $fields = [
            'openpaycongo/operator-payment-pattern',
            '2',
            $release['provider'],
            $release['sender'],
            $release['template'],
            (string) $release['pattern_version'],
            $release['approved_at'],
            $release['expires_at'],
        ];
        $transcript = '';
        foreach ($fields as $field) {
            $transcript .= pack('n', strlen($field)).$field;
        }

        return $transcript;
    }

    private function base64Url(string $value): string
    {
        return rtrim(strtr(base64_encode($value), '+/', '-_'), '=');
    }

    private function decodeBase64Url(string $value): string
    {
        $decoded = base64_decode(strtr($value.str_repeat('=', (4 - strlen($value) % 4) % 4), '-_', '+/'), true);
        self::assertIsString($decoded);

        return $decoded;
    }
}
