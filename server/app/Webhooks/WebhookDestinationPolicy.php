<?php

namespace App\Webhooks;

use InvalidArgumentException;

final class WebhookDestinationPolicy
{
    public function __construct(private readonly WebhookDnsResolver $dns) {}

    public function validateUrl(string $url): string
    {
        if ($this->isTestReceiver($url)) {
            return $url;
        }
        $parts = parse_url($url);
        $allowed = config('webhooks.allowed_hosts', []);
        $host = is_array($parts) ? ($parts['host'] ?? '') : '';
        if (! is_array($parts) || strlen($url) > 2048 || preg_match('/[\x00-\x20\x7f\\\\]/', $url)
            || ($parts['scheme'] ?? '') !== 'https'
            || isset($parts['user']) || isset($parts['pass'])
            || isset($parts['query']) || isset($parts['fragment'])
            || ($parts['port'] ?? 443) !== 443
            || ! preg_match('/\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/D', $host)
            || filter_var($host, FILTER_VALIDATE_IP) !== false
            || ! is_array($allowed) || ! in_array($host, $allowed, true)) {
            throw new InvalidArgumentException('destination_rejected');
        }

        return $url;
    }

    /** @return array{host: string, port: int, ip: string, test: bool} */
    public function resolve(string $url): array
    {
        $this->validateUrl($url);
        $parts = parse_url($url);
        if (! is_array($parts) || ! isset($parts['host'])) {
            throw new InvalidArgumentException('destination_rejected');
        }
        $host = $parts['host'];
        $test = $this->isTestReceiver($url);
        $addresses = $this->dns->resolve($host);
        if ($addresses === []) {
            throw new InvalidArgumentException('destination_dns_failed');
        }
        foreach ($addresses as $ip) {
            if (! $test && ! $this->isPublicAddress($ip)) {
                throw new InvalidArgumentException('destination_address_rejected');
            }
        }

        return ['host' => $host, 'port' => $parts['port'] ?? 443, 'ip' => $addresses[0], 'test' => $test];
    }

    private function isTestReceiver(string $url): bool
    {
        $receiver = config('webhooks.test_receiver_url');

        return app()->environment('testing') && is_string($receiver) && $receiver !== '' && hash_equals($receiver, $url);
    }

    private function isPublicAddress(string $ip): bool
    {
        $packed = @inet_pton($ip);
        if ($packed === false) {
            return false;
        }
        if (strlen($packed) === 4) {
            foreach (['0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16', '172.16.0.0/12', '192.0.0.0/24', '192.0.2.0/24', '192.88.99.0/24', '192.168.0.0/16', '198.18.0.0/15', '198.51.100.0/24', '203.0.113.0/24', '224.0.0.0/4', '240.0.0.0/4'] as $range) {
                if ($this->inRange($packed, $range)) {
                    return false;
                }
            }

            return true;
        }

        // Only global unicast; exclude transition, special-purpose and documentation ranges.
        return $this->inRange($packed, '2000::/3')
            && ! $this->inRange($packed, '2001::/23')
            && ! $this->inRange($packed, '2001:db8::/32')
            && ! $this->inRange($packed, '2002::/16')
            && ! $this->inRange($packed, '3fff::/20');
    }

    private function inRange(string $packed, string $range): bool
    {
        [$network, $prefix] = explode('/', $range);
        $networkBytes = inet_pton($network);
        if ($networkBytes === false || strlen($packed) !== strlen($networkBytes)) {
            return false;
        }
        $bits = (int) $prefix;
        $bytes = intdiv($bits, 8);
        $remainder = $bits % 8;

        return substr($packed, 0, $bytes) === substr($networkBytes, 0, $bytes)
            && ($remainder === 0 || (ord($packed[$bytes]) & (255 << (8 - $remainder))) === (ord($networkBytes[$bytes]) & (255 << (8 - $remainder))));
    }
}
