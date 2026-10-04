<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\Models\ApprovedSmsParserRelease;
use App\Models\CustomerCredit;
use App\Models\CustomerCreditPosting;
use App\Models\Deposit;
use App\Models\LedgerEntry;
use App\Models\SourceInstallation;
use App\PaymentRequests\AllocatePendingPaymentRequests;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

final class SmsDepositEnvelopeIntegrationTest extends TestCase
{
    use RefreshDatabase;

    private const string InstallationId = '00000000-0000-4000-8000-000000000029';

    public function test_encrypted_sms_deposit_requires_release_evidence_and_replays_wallet_credit_once(): void
    {
        $installation = $this->installation();
        $receivedAt = CarbonImmutable::now('UTC')->startOfSecond();
        $releaseId = hash('sha256', 'sms-deposit-integration-release');
        ApprovedSmsParserRelease::query()->create([
            'release_id' => $releaseId,
            'provider' => 'OPERATOR_A',
            'sender' => '12345',
            'template' => 'Received {amount} {currency}; ref {reference}; customer {customer}; at {occurred_at}',
            'pattern_version' => 1,
            'approved_at' => $receivedAt->subMinute(),
            'expires_at' => $receivedAt->addDay(),
            'signature' => $this->encode(str_repeat('s', SODIUM_CRYPTO_SIGN_BYTES)),
            'signing_public_key' => $this->encode(str_repeat('p', SODIUM_CRYPTO_SIGN_PUBLICKEYBYTES)),
        ]);
        $payload = [
            'customer_lookup_identifier' => 'sms-wallet-customer-001',
            'provider_reference' => 'sms-wallet-reference-001',
            'amount_minor' => 12500,
            'currency' => 'CDF',
            'provider_occurred_at' => '2026-09-30T01:00:00Z',
            'sender_identifier' => '12345',
            'parser_evidence' => [
                'kind' => 'signed_release',
                'provider' => 'OPERATOR_A',
                'sms_sender' => '12345',
                'parser_version' => 1,
                'sms_received_at' => $receivedAt->format('Y-m-d\\TH:i:s\\Z'),
                'evidence_digest' => hash('sha256', 'synthetic integration SMS body'),
                'parser_release_id' => $releaseId,
            ],
        ];

        $missingEvidence = $payload;
        unset($missingEvidence['parser_evidence']);
        $this->postJson('/mobile/envelopes', $this->envelope($installation, '1', $missingEvidence, 'sms_deposit'))
            ->assertNotFound()
            ->assertExactJson(['code' => 'mobile_envelope_unavailable']);
        self::assertSame(0, $installation->fresh()->mobile_replay_counter);
        self::assertDatabaseCount('deposits', 0);

        $recorded = $this->postJson('/mobile/envelopes', $this->envelope($installation, '1', $payload, 'sms_deposit'));
        $recorded->assertCreated();
        self::assertSame(['outcome' => 'recorded'], $this->decryptResponse($installation, '1', 201, $recorded->json()));

        // The operating system may report a new observation time when the same SMS is redelivered.
        // Financial idempotency still identifies the same transfer and preserves the first evidence.
        $payload['parser_evidence']['sms_received_at'] = $receivedAt->addSecond()->format('Y-m-d\\TH:i:s\\Z');
        $replayed = $this->postJson('/mobile/envelopes', $this->envelope($installation, '2', $payload, 'sms_deposit'));
        $replayed->assertOk();
        self::assertSame(['outcome' => 'replayed'], $this->decryptResponse($installation, '2', 200, $replayed->json()));

        $deposit = Deposit::query()->sole();
        // Execute the after-commit worker twice to verify its posting fence is idempotent too.
        app(AllocatePendingPaymentRequests::class)->forDepositId($deposit->id);
        app(AllocatePendingPaymentRequests::class)->forDepositId($deposit->id);
        self::assertSame($receivedAt->format('Y-m-d\\TH:i:s\\Z'), $deposit->parser_evidence['sms_received_at']);
        self::assertSame(2, $installation->fresh()->mobile_replay_counter);
        self::assertSame(2, LedgerEntry::query()->where('deposit_id', $deposit->id)->count());
        self::assertSame(1, CustomerCreditPosting::query()->where('deposit_id', $deposit->id)->count());
        self::assertSame(1, CustomerCredit::query()->where('customer_id', $deposit->customer_id)->count());
        self::assertSame(12500, (int) CustomerCredit::query()->where('customer_id', $deposit->customer_id)->sole()->available_minor);
    }

    private function installation(): SourceInstallation
    {
        return SourceInstallation::query()->create([
            'id' => self::InstallationId,
            'organization_id' => '00000000-0000-4000-8000-000000000001',
            'installation_digest' => hash('sha256', self::InstallationId),
            'installation_lookup_id' => self::InstallationId,
            'installation_key_version' => 'v1',
            'mobile_receive_key' => random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES),
            'mobile_send_key' => random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES),
            'mobile_replay_counter' => 0,
        ]);
    }

    /** @param array<string, mixed> $payload @return array<string, int|string> */
    private function envelope(SourceInstallation $installation, string $counter, array $payload, string $operation): array
    {
        $nonce = random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES);
        $plaintext = json_encode(['version' => 1, 'operation' => $operation, 'payload' => $payload], JSON_THROW_ON_ERROR);
        $ciphertext = sodium_crypto_aead_xchacha20poly1305_ietf_encrypt(
            $plaintext,
            $this->requestAad($installation->id, $counter),
            $nonce,
            $installation->mobile_receive_key,
        );

        return [
            'version' => 1,
            'installation_id' => $installation->id,
            'counter' => $counter,
            'nonce' => $this->encode($nonce),
            'ciphertext' => $this->encode($ciphertext),
        ];
    }

    /** @param array<string, string|int> $outer @return array<string, string> */
    private function decryptResponse(SourceInstallation $installation, string $counter, int $status, array $outer): array
    {
        $plaintext = sodium_crypto_aead_xchacha20poly1305_ietf_decrypt(
            $this->decode((string) $outer['ciphertext']),
            $this->responseAad($installation->id, $counter, $status),
            $this->decode((string) $outer['nonce']),
            $installation->mobile_send_key,
        );
        self::assertNotFalse($plaintext);

        return json_decode($plaintext, true, 512, JSON_THROW_ON_ERROR);
    }

    private function requestAad(string $id, string $counter): string
    {
        return pack('n', 39).'openpaycongo/mobile/request-envelope/v1'.$this->uuid($id).$this->counterBytes($counter);
    }

    private function responseAad(string $id, string $counter, int $status): string
    {
        return pack('n', 40).'openpaycongo/mobile/response-envelope/v1'.$this->uuid($id).$this->counterBytes($counter).pack('n', $status);
    }

    private function counterBytes(string $counter): string
    {
        $value = (int) $counter;

        return pack('N2', intdiv($value, 4_294_967_296), $value % 4_294_967_296);
    }

    private function uuid(string $id): string
    {
        return hex2bin(str_replace('-', '', $id));
    }

    private function encode(string $value): string
    {
        return rtrim(strtr(base64_encode($value), '+/', '-_'), '=');
    }

    private function decode(string $value): string
    {
        return base64_decode(strtr($value.str_repeat('=', (4 - strlen($value) % 4) % 4), '-_', '+/'), true);
    }
}
