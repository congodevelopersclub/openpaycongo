<?php

namespace App\Jobs;

use App\Models\Deposit;
use App\Models\DeveloperCustomerAccess;
use App\Models\WalletWebhookDelivery;
use App\Webhooks\SendWalletWebhook;
use Carbon\CarbonImmutable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use Throwable;

final class DeliverWalletWebhook implements ShouldQueue
{
    use Queueable;

    public const MAX_ATTEMPTS = 8;

    public int $tries = 1;

    public int $timeout = 30;

    public function __construct(public readonly string $deliveryId) {}

    public function handle(SendWalletWebhook $sender): void
    {
        $token = (string) Str::uuid();
        $delivery = DB::transaction(function () use ($token): ?WalletWebhookDelivery {
            $delivery = WalletWebhookDelivery::query()->lockForUpdate()->find($this->deliveryId);
            $now = CarbonImmutable::now();
            if ($delivery === null || ! in_array($delivery->status, ['pending', 'retry'], true)
                || ($delivery->next_attempt_at !== null && $delivery->next_attempt_at->greaterThan($now))
                || ($delivery->claimed_at !== null && $delivery->claimed_at->greaterThan($now->subMinutes(5)))) {
                return null;
            }
            $endpoint = $delivery->webhookEndpoint()->firstOrFail();
            if (! $endpoint->enabled) {
                return null;
            }
            $application = $endpoint->developerApplication()->firstOrFail();
            $deposit = Deposit::query()->findOrFail($delivery->deposit_id);
            $client = $application->oauthClient()->first();
            if ($application->organization_id !== $deposit->organization_id
                || $client === null || $client->revoked
                || ! DeveloperCustomerAccess::query()->where('developer_application_id', $application->id)->where('customer_id', $deposit->customer_id)->exists()) {
                $delivery->forceFill(['status' => 'cancelled', 'last_error_code' => 'authorization_revoked', 'claimed_at' => null, 'claim_token' => null])->save();

                return null;
            }
            if ($delivery->attempts >= self::MAX_ATTEMPTS) {
                $delivery->forceFill(['status' => 'dead_letter', 'last_error_code' => 'attempt_limit', 'claimed_at' => null, 'claim_token' => null])->save();

                return null;
            }
            $delivery->forceFill(['claimed_at' => $now, 'claim_token' => $token, 'attempts' => $delivery->attempts + 1])->save();
            $delivery->setRelation('webhookEndpoint', $endpoint);

            return $delivery;
        });
        if ($delivery === null) {
            return;
        }

        $error = null;
        try {
            $status = $sender->send($delivery->webhookEndpoint, $delivery);
            if ($status < 200 || $status >= 300) {
                $error = $status >= 300 && $status < 400 ? 'redirect_rejected' : 'http_'.$status;
            }
        } catch (Throwable $exception) {
            // Never retain request URLs, response bodies, credentials or raw transport exceptions.
            $safe = ['destination_rejected', 'destination_dns_failed', 'destination_address_rejected', 'transport_unavailable'];
            $error = in_array($exception->getMessage(), $safe, true) ? $exception->getMessage() : 'transport_failed';
        }

        DB::transaction(function () use ($token, $error): void {
            $delivery = WalletWebhookDelivery::query()->lockForUpdate()->findOrFail($this->deliveryId);
            if ($delivery->claim_token !== $token) {
                return;
            }
            $now = CarbonImmutable::now();
            $delivery->forceFill([
                'status' => $error === null ? 'delivered' : ($delivery->attempts >= self::MAX_ATTEMPTS ? 'dead_letter' : 'retry'),
                'delivered_at' => $error === null ? $now : null,
                'last_error_code' => $error,
                'claimed_at' => null,
                'claim_token' => null,
                'next_attempt_at' => $error === null ? null : $now->addSeconds(min(3600, 30 * (2 ** ($delivery->attempts - 1)))),
            ])->save();
        });
    }
}
