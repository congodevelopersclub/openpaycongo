<?php

namespace App\Console\Commands;

use App\Jobs\DeliverWalletWebhook;
use App\Models\WalletWebhookDelivery;
use Illuminate\Console\Command;

final class RecoverWalletWebhookDeliveries extends Command
{
    protected $signature = 'wallet-webhooks:recover-deliveries';

    protected $description = 'Re-enqueue due wallet webhook outbox deliveries and stale claims.';

    public function handle(): int
    {
        WalletWebhookDelivery::query()->whereIn('status', ['pending', 'retry'])
            ->whereHas('webhookEndpoint', fn ($query) => $query->where('enabled', true))
            ->where(fn ($query) => $query->whereNull('next_attempt_at')->orWhere('next_attempt_at', '<=', now()))
            ->where(fn ($query) => $query->whereNull('claimed_at')->orWhere('claimed_at', '<=', now()->subMinutes(5)))
            ->eachById(fn (WalletWebhookDelivery $delivery) => DeliverWalletWebhook::dispatch($delivery->id));

        return self::SUCCESS;
    }
}
