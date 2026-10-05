<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\DeveloperApplications\CustomerWalletAccess;
use App\DeveloperApplications\ManageDeveloperApplicationCredentials;
use App\Filament\Pages\ReconcileDeposit;
use App\Models\Deposit;
use App\Models\Organization;
use App\Models\SourceInstallation;
use App\Models\User;
use App\Models\WalletWebhookDelivery;
use App\OperatorSms\OperatorPaymentPatternReview;
use App\OperatorSms\ReleaseApprovedOperatorPaymentPattern;
use App\Security\EstablishFinancialOperatorMfaSession;
use App\Webhooks\ManageWebhookEndpoint;
use App\Webhooks\SendWalletWebhook;
use Carbon\CarbonImmutable;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\DatabaseTruncation;
use Illuminate\Foundation\Testing\RefreshDatabaseState;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\DB;
use Livewire\Livewire;
use PDO;
use Tests\Support\WalletWebhookTestCase;

final class SmsToWalletEndToEndTest extends WalletWebhookTestCase
{
    use DatabaseTruncation;

    protected function beforeTruncatingDatabase(): void
    {
        RefreshDatabaseState::$migrated = false;
        RefreshDatabaseState::$inMemoryConnections = [];
    }

    protected function tearDown(): void
    {
        RefreshDatabaseState::$migrated = false;
        RefreshDatabaseState::$inMemoryConnections = [];
        parent::tearDown();
    }

    public function test_one_encrypted_sms_deposit_is_visible_in_admin_and_oauth_wallet_and_delivered_once_to_a_real_receiver(): void
    {
        // This server contract starts at approved parser output; native SMS parsing is verified separately.
        $this->withReceiver(function (string $receiverUrl, string $databasePath): void {
            config([
                'queue.default' => 'sync',
                'webhooks.allowed_hosts' => [],
                'webhooks.test_receiver_url' => $receiverUrl,
                'openpay.operator_sms_patterns.signing_secret' => $this->encode(str_repeat("\x01", SODIUM_CRYPTO_SIGN_SEEDBYTES)),
            ]);
            $this->dns(['127.0.0.1']);
            Artisan::call('passport:keys', ['--force' => true]);
            Filament::setCurrentPanel(Filament::getPanel('operations'));
            $organization = Organization::query()->forceCreate([]);
            $actor = User::factory()->create(['organization_id' => $organization->id, 'is_financial_operator' => true]);
            $actor->forceFill(['two_factor_confirmed_at' => now(), 'recovery_codes_confirmed_at' => now()])->save();
            $this->actingAs($actor);
            $this->withSession([]);
            app(EstablishFinancialOperatorMfaSession::class)->establish($actor, app('session.store'));
            $issued = app(ManageDeveloperApplicationCredentials::class)->issue($actor, 'Synthetic SMS wallet consumer', ['wallets:read']);
            $customer = app(CustomerWalletAccess::class)->provision($actor, $issued->application->id, 'synthetic-e2e-customer');
            $endpoint = app(ManageWebhookEndpoint::class)->configure($actor, $issued->application->id, $receiverUrl, self::SECRET, true);

            $review = app(OperatorPaymentPatternReview::class);
            $proposal = $review->proposeManual($actor, 'OPERATOR_A', '12345', 'Received {amount} {currency}; ref {reference}; customer {customer}; at {occurred_at}');
            self::assertSame('pending_review', $proposal->status);
            $approved = $review->approve($actor, $proposal);
            $release = app(ReleaseApprovedOperatorPaymentPattern::class)->release($actor, $approved, CarbonImmutable::now('UTC')->addDay()->startOfSecond());
            self::assertSame('approved', $approved->status);
            self::assertSame('1', json_decode($release->encoded_release, true, flags: JSON_THROW_ON_ERROR)['schema_version']);
            $installation = SourceInstallation::query()->create([
                'organization_id' => $organization->id,
                'installation_digest' => hash('sha256', 'synthetic-e2e-installation'),
                'mobile_receive_key' => random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES),
                'mobile_send_key' => random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES),
                'mobile_replay_counter' => 0,
            ]);
            $receivedAt = CarbonImmutable::now('UTC')->startOfSecond();
            $payload = [
                'customer_lookup_identifier' => 'synthetic-e2e-customer',
                'provider_reference' => 'synthetic-e2e-provider-reference',
                'amount_minor' => 12500,
                'currency' => 'CDF',
                'provider_occurred_at' => '2026-09-30T01:00:00Z',
                'sender_identifier' => '12345',
                'parser_evidence' => [
                    'kind' => 'signed_release', 'provider' => 'OPERATOR_A', 'sms_sender' => '12345', 'parser_version' => $release->pattern_version,
                    'sms_received_at' => $receivedAt->format('Y-m-d\TH:i:s\Z'),
                    'evidence_digest' => hash('sha256', 'Synthetic SMS observation for the integration test'),
                    'parser_release_id' => $release->parser_release_digest,
                ],
            ];
            $first = $this->postJson('/mobile/envelopes', $this->envelope($installation, 1, $payload))->assertCreated();
            self::assertSame(['outcome' => 'recorded'], $this->decryptResponse($installation, 1, 201, $first->json()));
            $duplicate = $this->postJson('/mobile/envelopes', $this->envelope($installation, 2, $payload))->assertOk();
            self::assertSame(['outcome' => 'replayed'], $this->decryptResponse($installation, 2, 200, $duplicate->json()));
            self::assertSame(0, DB::transactionLevel());
            self::assertSame(2, $installation->fresh()->mobile_replay_counter);
            self::assertDatabaseCount('deposits', 1);
            self::assertDatabaseCount('ledger_entries', 2);
            self::assertDatabaseCount('customer_credit_postings', 1);
            self::assertDatabaseCount('wallet_webhook_deliveries', 1);
            self::assertDatabaseHas('customer_credits', ['customer_id' => $customer->id, 'currency' => 'CDF', 'available_minor' => 12500]);
            $deposit = Deposit::query()->sole();
            self::assertSame($customer->id, $deposit->customer_id);
            self::assertSame($installation->id, $deposit->source_installation_id);
            self::assertSame($release->parser_release_digest, $deposit->parser_evidence['parser_release_id']);

            Livewire::actingAs($actor)->test(ReconcileDeposit::class, ['deposit' => $deposit->id])
                ->assertSet('isReconciled', true)->assertSee($customer->id)->assertSee($installation->id)->assertSee('12500')
                ->assertSee('Unverified')->assertSee($release->parser_release_digest)
                ->assertDontSee($payload['provider_reference'])->assertDontSee($payload['customer_lookup_identifier']);
            $foreign = User::factory()->create(['organization_id' => Organization::query()->forceCreate([])->id, 'is_financial_operator' => true]);
            $foreign->forceFill(['two_factor_confirmed_at' => now(), 'recovery_codes_confirmed_at' => now()])->save();
            $this->actingAs($foreign);
            app(EstablishFinancialOperatorMfaSession::class)->establish($foreign, app('session.store'));
            Livewire::actingAs($foreign)->test(ReconcileDeposit::class, ['deposit' => $deposit->id])->assertForbidden();
            $this->actingAs($actor);
            app(EstablishFinancialOperatorMfaSession::class)->establish($actor, app('session.store'));

            $token = (string) $this->postJson('/oauth/token', [
                'grant_type' => 'client_credentials', 'client_id' => $issued->clientId,
                'client_secret' => $issued->clientSecret, 'scope' => 'wallets:read',
            ])->assertOk()->json('access_token');
            $this->withToken($token)->getJson('/services/customers/'.$customer->id.'/wallet')
                ->assertOk()->assertExactJson([
                    'customer_id' => $customer->id, 'settlement_status' => 'unverified',
                    'balances' => [['currency' => 'CDF', 'available_minor' => 12500]],
                ])->assertDontSee($payload['provider_reference'])->assertDontSee($payload['customer_lookup_identifier']);
            $delivery = WalletWebhookDelivery::query()->sole();
            self::assertSame($endpoint->id, $delivery->webhook_endpoint_id);
            self::assertSame($deposit->id, $delivery->deposit_id);
            self::assertSame('delivered', $delivery->status);
            self::assertSame(1, $delivery->attempts);
            self::assertSame([
                'event_id' => $delivery->event_id, 'type' => 'wallet.credit_posted', 'customer_id' => $customer->id,
                'deposit_id' => $deposit->id, 'amount_minor' => 12500, 'currency' => 'CDF', 'available_minor' => 12500, 'settlement_status' => 'unverified',
            ], json_decode($delivery->body, true, flags: JSON_THROW_ON_ERROR));
            // Repeat the same signed event over actual HTTP to prove the receiver's transactional inbox fence.
            self::assertSame(200, app(SendWalletWebhook::class)->send($endpoint, $delivery));
            $consumer = new PDO('sqlite:'.$databasePath);
            self::assertSame(1, (int) $consumer->query('SELECT COUNT(*) FROM received_wallet_events')->fetchColumn());
            self::assertSame($delivery->event_id, $consumer->query('SELECT event_id FROM received_wallet_events')->fetchColumn());
            self::assertSame(12500, (int) $consumer->query('SELECT amount_minor FROM wallet_credit_totals')->fetchColumn());
        });
    }

    private function withReceiver(callable $scenario): void
    {
        $router = dirname(base_path()).'/examples/webhook-receiver.php';
        self::assertFileExists($router);
        $socket = stream_socket_server('tcp://127.0.0.1:0');
        self::assertIsResource($socket);
        $address = stream_socket_get_name($socket, false);
        self::assertIsString($address);
        $port = (int) substr($address, strrpos($address, ':') + 1);
        fclose($socket);
        $databasePath = tempnam(sys_get_temp_dir(), 'sms-wallet-consumer-');
        $logPath = tempnam(sys_get_temp_dir(), 'sms-wallet-receiver-');
        self::assertIsString($databasePath);
        self::assertIsString($logPath);
        $process = null;
        try {
            $process = proc_open([PHP_BINARY, '-d', 'display_errors=0', '-S', '127.0.0.1:'.$port, $router], [
                0 => ['file', '/dev/null', 'r'], 1 => ['file', $logPath, 'a'], 2 => ['file', $logPath, 'a'],
            ], $pipes, base_path(), array_merge(getenv(), [
                'OPENPAY_WEBHOOK_SIGNING_SECRET' => self::SECRET, 'OPENPAY_WEBHOOK_RECEIVER_DB' => $databasePath,
            ]));
            self::assertIsResource($process);
            $ready = false;
            $deadline = microtime(true) + 5;
            do {
                $connection = @fsockopen('127.0.0.1', $port, $errorCode, $errorMessage, 0.1);
                if (is_resource($connection)) {
                    fclose($connection);
                    $ready = true;
                    break;
                }
                usleep(50000);
            } while (microtime(true) < $deadline);
            self::assertTrue($ready, 'Controlled HTTP receiver failed to start.');
            $scenario('http://receiver.example:'.$port.'/wallet', $databasePath);
        } finally {
            if (is_resource($process)) {
                proc_terminate($process);
                proc_close($process);
            }
            foreach ([$databasePath, $databasePath.'-journal', $databasePath.'-wal', $databasePath.'-shm', $logPath] as $temporary) {
                if (is_file($temporary)) {
                    unlink($temporary);
                }
            }
        }
    }

    /** @param array<string, mixed> $payload @return array<string, int|string> */
    private function envelope(SourceInstallation $installation, int $counter, array $payload): array
    {
        $nonce = random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES);
        $plaintext = json_encode(['version' => 1, 'operation' => 'sms_deposit', 'payload' => $payload], JSON_THROW_ON_ERROR);
        $ciphertext = sodium_crypto_aead_xchacha20poly1305_ietf_encrypt(
            $plaintext,
            pack('n', 39).'openpaycongo/mobile/request-envelope/v1'.$this->uuidBytes($installation->id).$this->counterBytes($counter),
            $nonce,
            $installation->mobile_receive_key,
        );

        return ['version' => 1, 'installation_id' => $installation->id, 'counter' => (string) $counter, 'nonce' => $this->encode($nonce), 'ciphertext' => $this->encode($ciphertext)];
    }

    /** @param array<string, string|int> $outer @return array<string, string> */
    private function decryptResponse(SourceInstallation $installation, int $counter, int $status, array $outer): array
    {
        $plaintext = sodium_crypto_aead_xchacha20poly1305_ietf_decrypt(
            $this->decode((string) $outer['ciphertext']),
            pack('n', 40).'openpaycongo/mobile/response-envelope/v1'.$this->uuidBytes($installation->id).$this->counterBytes($counter).pack('n', $status),
            $this->decode((string) $outer['nonce']),
            $installation->mobile_send_key,
        );
        self::assertNotFalse($plaintext);

        return json_decode($plaintext, true, 512, JSON_THROW_ON_ERROR);
    }

    private function counterBytes(int $counter): string
    {
        return pack('N2', intdiv($counter, 4_294_967_296), $counter % 4_294_967_296);
    }

    private function uuidBytes(string $id): string
    {
        $bytes = hex2bin(str_replace('-', '', $id));
        self::assertIsString($bytes);

        return $bytes;
    }

    private function encode(string $bytes): string
    {
        return rtrim(strtr(base64_encode($bytes), '+/', '-_'), '=');
    }

    private function decode(string $value): string
    {
        $bytes = base64_decode(strtr($value.str_repeat('=', (4 - strlen($value) % 4) % 4), '-_', '+/'), true);
        self::assertIsString($bytes);

        return $bytes;
    }
}
