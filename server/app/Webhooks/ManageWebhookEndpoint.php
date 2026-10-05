<?php

namespace App\Webhooks;

use App\Jobs\DeliverWalletWebhook;
use App\Models\DeveloperApplication;
use App\Models\User;
use App\Models\WalletWebhookDelivery;
use App\Models\WebhookEndpoint;
use App\Security\FinancialOperatorMfaSession;
use Illuminate\Auth\Access\AuthorizationException;
use Illuminate\Support\Facades\DB;
use InvalidArgumentException;

final class ManageWebhookEndpoint
{
    public function __construct(private readonly FinancialOperatorMfaSession $mfa, private readonly WebhookDestinationPolicy $destinations) {}

    public function configure(User $actor, string $applicationId, string $url, string $signingSecret, bool $enabled): WebhookEndpoint
    {
        $this->authorize($actor, $applicationId);
        $url = $this->destinations->validateUrl($url);
        if (strlen($signingSecret) < 32 || strlen($signingSecret) > 512) {
            throw new InvalidArgumentException('A signing secret of 32 to 512 bytes is required.');
        }

        return DB::transaction(function () use ($actor, $applicationId, $url, $signingSecret, $enabled): WebhookEndpoint {
            DeveloperApplication::query()->lockForUpdate()->findOrFail($applicationId);
            $this->authorize($actor, $applicationId);

            return WebhookEndpoint::query()->updateOrCreate(['developer_application_id' => $applicationId], [
                'url' => $url,
                'signing_secret' => $signingSecret,
                'enabled' => $enabled,
                'configured_by_user_id' => $actor->getKey(),
            ]);
        });
    }

    public function pause(User $actor, string $applicationId): WebhookEndpoint
    {
        $this->authorize($actor, $applicationId);
        $endpoint = WebhookEndpoint::query()->where('developer_application_id', $applicationId)->firstOrFail();
        $endpoint->forceFill(['enabled' => false, 'configured_by_user_id' => $actor->getKey()])->save();

        return $endpoint;
    }

    public function replay(User $actor, string $applicationId, string $deliveryId): WalletWebhookDelivery
    {
        $this->authorize($actor, $applicationId);

        return DB::transaction(function () use ($applicationId, $deliveryId): WalletWebhookDelivery {
            $endpoint = WebhookEndpoint::query()->where('developer_application_id', $applicationId)->firstOrFail();
            $delivery = WalletWebhookDelivery::query()->where('webhook_endpoint_id', $endpoint->id)->lockForUpdate()->findOrFail($deliveryId);
            if (! $endpoint->enabled || ! in_array($delivery->status, ['retry', 'dead_letter', 'cancelled'], true)
                || ($delivery->claimed_at !== null && $delivery->claimed_at->greaterThan(now()->subMinutes(5)))) {
                throw new InvalidArgumentException('Enable the endpoint and select a failed delivery to replay.');
            }
            $delivery->forceFill(['status' => 'pending', 'attempts' => 0, 'claimed_at' => null, 'claim_token' => null, 'next_attempt_at' => now(), 'last_error_code' => null])->save();
            DeliverWalletWebhook::dispatch($delivery->id)->afterCommit();

            return $delivery;
        });
    }

    private function authorize(User $actor, string $applicationId): void
    {
        $this->mfa->assertVerified($actor);
        if (! $actor->is_financial_operator || ! is_string($actor->organization_id)
            || ! DeveloperApplication::query()->whereKey($applicationId)->where('organization_id', $actor->organization_id)->exists()) {
            throw new AuthorizationException;
        }
    }
}
