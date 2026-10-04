<?php

namespace App\Webhooks;

use App\Jobs\DeliverWalletWebhook;
use App\Models\CustomerCredit;
use App\Models\Deposit;
use App\Models\DeveloperCustomerAccess;
use App\Models\WalletWebhookDelivery;
use App\Models\WebhookEndpoint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use LogicException;

final class RecordWalletCreditWebhook
{
    public function record(Deposit $deposit, CustomerCredit $credit): void
    {
        if (DB::transactionLevel() === 0) {
            throw new LogicException('The webhook outbox must be recorded in the credit transaction.');
        }
        $applications = DeveloperCustomerAccess::query()->where('customer_id', $deposit->customer_id)->select('developer_application_id');
        $endpoints = WebhookEndpoint::query()->where('enabled', true)
            ->whereIn('developer_application_id', $applications)
            ->whereHas('developerApplication', fn ($query) => $query->where('organization_id', $deposit->organization_id))
            ->get();
        foreach ($endpoints as $endpoint) {
            $eventId = (string) Str::uuid();
            $delivery = WalletWebhookDelivery::query()->firstOrCreate([
                'webhook_endpoint_id' => $endpoint->id,
                'deposit_id' => $deposit->id,
            ], [
                'event_id' => $eventId,
                'body' => json_encode([
                    'event_id' => $eventId,
                    'type' => 'wallet.credit_posted',
                    'customer_id' => $deposit->customer_id,
                    'deposit_id' => $deposit->id,
                    'amount_minor' => (int) $deposit->amount_minor,
                    'currency' => $deposit->currency,
                    'available_minor' => (int) $credit->available_minor,
                    'settlement_status' => 'unverified',
                ], JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES),
                'status' => 'pending',
                'next_attempt_at' => now(),
            ]);
            DeliverWalletWebhook::dispatch($delivery->id)->afterCommit();
        }
    }
}
