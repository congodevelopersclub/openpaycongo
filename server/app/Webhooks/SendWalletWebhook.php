<?php

namespace App\Webhooks;

use App\Models\WalletWebhookDelivery;
use App\Models\WebhookEndpoint;
use GuzzleHttp\Handler\CurlHandler;
use Illuminate\Support\Facades\Http;
use RuntimeException;

final class SendWalletWebhook
{
    public function __construct(private readonly WebhookDestinationPolicy $destinations) {}

    public function send(WebhookEndpoint $endpoint, WalletWebhookDelivery $delivery): int
    {
        $destination = $this->destinations->resolve($endpoint->url);
        if (! extension_loaded('curl')) {
            throw new RuntimeException('transport_unavailable');
        }
        $ip = str_contains($destination['ip'], ':') ? '['.$destination['ip'].']' : $destination['ip'];
        $timestamp = (string) now()->timestamp;
        $signature = hash_hmac('sha256', $timestamp.'.'.$delivery->body, $endpoint->signing_secret);
        $timeout = max(1, min(15, (int) config('webhooks.timeout_seconds', 5)));

        // Require cURL: a stream-handler fallback would ignore DNS pinning.
        return Http::withOptions([
            'allow_redirects' => false,
            'verify' => true,
            'protocols' => $destination['test'] ? ['http', 'https'] : ['https'],
            // An explicit empty proxy disables Guzzle's environment proxy fallback.
            'proxy' => '',
            'curl' => [
                CURLOPT_RESOLVE => [$destination['host'].':'.$destination['port'].':'.$ip],
            ],
        ])->setHandler(new CurlHandler)->timeout($timeout)->connectTimeout($timeout)
            ->withHeaders([
                'Webhook-Id' => $delivery->event_id,
                'Webhook-Timestamp' => $timestamp,
                'Webhook-Signature' => 'v1='.$signature,
            ])->withBody($delivery->body, 'application/json')->post($endpoint->url)->status();
    }
}
