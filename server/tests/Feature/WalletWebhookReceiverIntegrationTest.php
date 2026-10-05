<?php

namespace Tests\Feature;

use App\Deposits\ProviderTransfer;
use App\Deposits\RecordProviderDeposit;
use App\Jobs\DeliverWalletWebhook;
use App\Models\SourceInstallation;
use App\Models\WalletWebhookDelivery;
use App\PaymentRequests\AllocatePendingPaymentRequests;
use App\PaymentRequests\CreatePaymentRequest;
use App\PaymentRequests\PaymentRequestStatus;
use App\Reconciliation\ReverseDeposit;
use App\Webhooks\SendWalletWebhook;
use App\Webhooks\WebhookDestinationPolicy;
use Illuminate\Foundation\Testing\DatabaseTruncation;
use Illuminate\Foundation\Testing\RefreshDatabaseState;
use Illuminate\Support\Facades\Http;
use InvalidArgumentException;
use PDO;
use Tests\Support\WalletWebhookTestCase;

final class WalletWebhookReceiverIntegrationTest extends WalletWebhookTestCase
{
    use DatabaseTruncation;

    protected function beforeTruncatingDatabase(): void
    {
        // Real commit proof must run without RefreshDatabase's wrapping transaction.
        RefreshDatabaseState::$migrated = false;
        RefreshDatabaseState::$inMemoryConnections = [];
    }

    protected function tearDown(): void
    {
        RefreshDatabaseState::$migrated = false;
        RefreshDatabaseState::$inMemoryConnections = [];
        parent::tearDown();
    }

    public function test_real_http_receiver_verifies_signature_and_commits_one_effect_across_retries(): void
    {
        $router = dirname(base_path()).'/examples/webhook-receiver.php';
        self::assertFileExists($router);
        $socket = stream_socket_server('tcp://127.0.0.1:0');
        self::assertIsResource($socket);
        $address = stream_socket_get_name($socket, false);
        self::assertIsString($address);
        $port = (int) substr($address, strrpos($address, ':') + 1);
        fclose($socket);
        $databasePath = tempnam(sys_get_temp_dir(), 'wallet-consumer-');
        $logPath = tempnam(sys_get_temp_dir(), 'wallet-receiver-');
        self::assertIsString($databasePath);
        self::assertIsString($logPath);
        $process = null;
        try {
            // The hostname has no public DNS record. The sender must use its validated cURL IP pin.
            $url = 'http://receiver.example:'.$port.'/wallet';
            config(['webhooks.test_receiver_url' => $url]);
            [, , , $deposit] = $this->fixture($url);
            $this->dns(['127.0.0.1']);
            app(AllocatePendingPaymentRequests::class)->forDeposit($deposit);
            app(AllocatePendingPaymentRequests::class)->forDeposit($deposit);
            self::assertDatabaseCount('deposits', 1);
            self::assertDatabaseCount('ledger_entries', 2);
            self::assertDatabaseCount('customer_credit_postings', 1);
            self::assertDatabaseHas('customer_credits', ['customer_id' => $deposit->customer_id, 'currency' => 'CDF', 'available_minor' => 12500]);
            $delivery = WalletWebhookDelivery::query()->sole();
            $eventId = $delivery->event_id;
            $body = $delivery->body;
            // Nothing is listening yet: a real failed TCP connection must leave a recoverable outbox row.
            (new DeliverWalletWebhook($delivery->id))->handle(app(SendWalletWebhook::class));
            $delivery->refresh();
            self::assertSame('retry', $delivery->status);
            self::assertSame(1, $delivery->attempts);
            self::assertSame('transport_failed', $delivery->last_error_code);
            self::assertNull($delivery->delivered_at);
            self::assertNotNull($delivery->next_attempt_at);
            $process = proc_open([PHP_BINARY, '-d', 'display_errors=0', '-S', '127.0.0.1:'.$port, $router], [
                0 => ['file', '/dev/null', 'r'], 1 => ['file', $logPath, 'a'], 2 => ['file', $logPath, 'a'],
            ], $pipes, base_path(), array_merge(getenv(), [
                'OPENPAY_WEBHOOK_SIGNING_SECRET' => self::SECRET,
                'OPENPAY_WEBHOOK_RECEIVER_DB' => $databasePath,
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
            // The first retry is only 30 seconds ahead, inside the real receiver's five-minute timestamp window.
            $this->travelTo($delivery->next_attempt_at);
            (new DeliverWalletWebhook($delivery->id))->handle(app(SendWalletWebhook::class));
            $delivery->refresh();
            self::assertSame('delivered', $delivery->status, 'Wallet webhook failed with safe code: '.($delivery->last_error_code ?? 'none'));
            self::assertSame(2, $delivery->attempts);
            self::assertSame($eventId, $delivery->event_id);
            self::assertSame($body, $delivery->body);
            self::assertNull($delivery->last_error_code);
            // Simulate a receiver commit followed by a lost sender acknowledgement: exact body/ID sent again.
            self::assertSame(200, app(SendWalletWebhook::class)->send($delivery->webhookEndpoint, $delivery));
            $database = new PDO('sqlite:'.$databasePath);
            self::assertSame(1, (int) $database->query('SELECT COUNT(*) FROM received_wallet_events')->fetchColumn());
            self::assertSame(12500, (int) $database->query('SELECT amount_minor FROM wallet_credit_totals')->fetchColumn());
            self::assertSame($delivery->event_id, $database->query('SELECT event_id FROM received_wallet_events')->fetchColumn());
            // Direct loopback requests exercise the receiver's authentication and event-conflict rules.
            $receiverUrl = 'http://127.0.0.1:'.$port.'/wallet';
            $changedPayload = json_decode($body, true, flags: JSON_THROW_ON_ERROR);
            $changedPayload['amount_minor'] = 12501;
            $changedBody = json_encode($changedPayload, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES);
            $timestamp = (string) time();
            $headers = [
                'Webhook-Id' => $eventId,
                'Webhook-Timestamp' => $timestamp,
                'Webhook-Signature' => 'v1='.hash_hmac('sha256', $timestamp.'.'.$changedBody, self::SECRET),
            ];
            self::assertSame(409, Http::withHeaders($headers)->withBody($changedBody, 'application/json')->post($receiverUrl)->status());
            self::assertSame(1, (int) $database->query('SELECT COUNT(*) FROM received_wallet_events')->fetchColumn());
            self::assertSame(12500, (int) $database->query('SELECT amount_minor FROM wallet_credit_totals')->fetchColumn());
            $headers = ['Webhook-Id' => $delivery->event_id, 'Webhook-Timestamp' => (string) time(), 'Webhook-Signature' => 'v1=invalid'];
            self::assertSame(401, Http::withHeaders($headers)->withBody($delivery->body, 'application/json')->post($receiverUrl)->status());
            $timestamp = (string) (time() - 600);
            $headers['Webhook-Timestamp'] = $timestamp;
            $headers['Webhook-Signature'] = 'v1='.hash_hmac('sha256', $timestamp.'.'.$delivery->body, self::SECRET);
            self::assertSame(401, Http::withHeaders($headers)->withBody($delivery->body, 'application/json')->post($receiverUrl)->status());
            self::assertSame(1, (int) $database->query('SELECT COUNT(*) FROM received_wallet_events')->fetchColumn());
            $database = null;
        } finally {
            $this->travelBack();
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

    public function test_receiver_override_cannot_enable_http_or_private_destinations_in_production(): void
    {
        $url = 'http://127.0.0.1:8765/wallet';
        config(['webhooks.test_receiver_url' => $url]);
        $this->app->instance('env', 'production');
        $this->expectException(InvalidArgumentException::class);
        app(WebhookDestinationPolicy::class)->validateUrl($url);
    }

    public function test_real_receiver_accepts_a_credit_snapshot_that_remains_negative_after_reversal_debt(): void
    {
        $router = dirname(base_path()).'/examples/webhook-receiver.php';
        self::assertFileExists($router);
        $socket = stream_socket_server('tcp://127.0.0.1:0');
        self::assertIsResource($socket);
        $address = stream_socket_get_name($socket, false);
        self::assertIsString($address);
        $port = (int) substr($address, strrpos($address, ':') + 1);
        fclose($socket);
        $databasePath = tempnam(sys_get_temp_dir(), 'wallet-debt-consumer-');
        $logPath = tempnam(sys_get_temp_dir(), 'wallet-debt-receiver-');
        self::assertIsString($databasePath);
        self::assertIsString($logPath);
        $process = null;
        try {
            $url = 'http://receiver.example:'.$port.'/wallet';
            config(['webhooks.test_receiver_url' => $url]);
            [$actor, , $customer, $deposit] = $this->fixture($url, 100);
            $this->dns(['127.0.0.1']);
            $process = proc_open([PHP_BINARY, '-d', 'display_errors=0', '-S', '127.0.0.1:'.$port, $router], [
                0 => ['file', '/dev/null', 'r'], 1 => ['file', $logPath, 'a'], 2 => ['file', $logPath, 'a'],
            ], $pipes, base_path(), array_merge(getenv(), [
                'OPENPAY_WEBHOOK_SIGNING_SECRET' => self::SECRET,
                'OPENPAY_WEBHOOK_RECEIVER_DB' => $databasePath,
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

            app(AllocatePendingPaymentRequests::class)->forDeposit($deposit);
            $firstDelivery = WalletWebhookDelivery::query()->where('deposit_id', $deposit->id)->sole();
            (new DeliverWalletWebhook($firstDelivery->id))->handle(app(SendWalletWebhook::class));
            $firstDelivery->refresh();
            self::assertSame('delivered', $firstDelivery->status, 'Wallet webhook failed with safe code: '.($firstDelivery->last_error_code ?? 'none'));
            self::assertNull($firstDelivery->last_error_code);
            $request = app(CreatePaymentRequest::class)->create($customer->id, 100, 'CDF', 'synthetic-reversal-debt-charge');
            self::assertSame(PaymentRequestStatus::Charged, $request->status);
            self::assertDatabaseHas('customer_credits', ['customer_id' => $customer->id, 'currency' => 'CDF', 'available_minor' => 0]);
            app(ReverseDeposit::class)->reverse($actor, $deposit, 'synthetic_debt_correction');
            self::assertDatabaseHas('customer_credits', ['customer_id' => $customer->id, 'currency' => 'CDF', 'available_minor' => -100]);

            $nextDeposit = app(RecordProviderDeposit::class)->record(new ProviderTransfer(
                organizationId: $deposit->organization_id,
                installationIdentifier: 'synthetic-webhook-installation',
                customerLookupIdentifier: 'synthetic-webhook-customer',
                providerReference: 'synthetic-webhook-debt-credit',
                amountMinor: 50,
                currency: 'CDF',
                providerOccurredAt: '2026-08-31T01:01:00Z',
                senderIdentifier: null,
                receiverIdentifier: null,
            ), SourceInstallation::query()->findOrFail($deposit->source_installation_id))->deposit;
            app(AllocatePendingPaymentRequests::class)->forDeposit($nextDeposit);
            $delivery = WalletWebhookDelivery::query()->where('deposit_id', $nextDeposit->id)->sole();
            $payload = json_decode($delivery->body, true, flags: JSON_THROW_ON_ERROR);
            self::assertSame(50, $payload['amount_minor']);
            self::assertSame(-50, $payload['available_minor']);
            self::assertSame('unverified', $payload['settlement_status']);
            self::assertDatabaseHas('customer_credits', ['customer_id' => $customer->id, 'currency' => 'CDF', 'available_minor' => -50]);
            self::assertDatabaseCount('ledger_entries', 6);
            self::assertDatabaseCount('customer_credit_postings', 3);
            self::assertDatabaseCount('wallet_webhook_deliveries', 2);
            (new DeliverWalletWebhook($delivery->id))->handle(app(SendWalletWebhook::class));
            $delivery->refresh();
            self::assertSame('delivered', $delivery->status, 'Wallet webhook failed with safe code: '.($delivery->last_error_code ?? 'none'));
            self::assertNull($delivery->last_error_code);
            $database = new PDO('sqlite:'.$databasePath);
            self::assertSame(2, (int) $database->query('SELECT COUNT(*) FROM received_wallet_events')->fetchColumn());
            self::assertSame(150, (int) $database->query('SELECT amount_minor FROM wallet_credit_totals')->fetchColumn());
            $database = null;
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
}
