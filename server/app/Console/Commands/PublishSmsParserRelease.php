<?php

declare(strict_types=1);

namespace App\Console\Commands;

use App\Models\ApprovedSmsParserRelease;
use Carbon\CarbonImmutable;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;
use JsonException;
use Throwable;

final class PublishSmsParserRelease extends Command
{
    protected $signature = 'sms-parser:publish
                            {provider : Stable provider identifier}
                            {sender : Exact trusted SMS sender identifier}
                            {template : Literal scanner template containing amount, currency, reference, customer, and occurred_at placeholders}
                            {pattern_version : Positive parser pattern version}
                            {expires_at : UTC RFC 3339 expiry, for example 2027-01-01T00:00:00Z}';

    protected $description = 'Sign and register an approved SMS parser pattern release.';

    /** @var list<string> */
    private const TEMPLATE_FIELDS = ['{amount}', '{currency}', '{reference}', '{customer}', '{occurred_at}'];

    public function handle(): int
    {
        try {
            $release = $this->release();
            DB::transaction(static function () use ($release): void {
                $record = $release['record'];
                $scopeId = hash('sha256', json_encode([$record['provider'], $record['sender']], JSON_THROW_ON_ERROR));
                DB::table('sms_parser_release_scopes')->insertOrIgnore([
                    'scope_id' => $scopeId,
                    'provider' => $record['provider'],
                    'sender' => $record['sender'],
                    'created_at' => now('UTC'),
                    'updated_at' => now('UTC'),
                ]);
                DB::table('sms_parser_release_scopes')->where('scope_id', $scopeId)->lockForUpdate()->firstOrFail();
                $latestVersion = ApprovedSmsParserRelease::query()
                    ->where('provider', $record['provider'])
                    ->where('sender', $record['sender'])
                    ->max('pattern_version');
                if ($latestVersion !== null && (int) $record['pattern_version'] <= (int) $latestVersion) {
                    throw new \InvalidArgumentException;
                }
                if (CarbonImmutable::parse($record['expires_at'])->lessThanOrEqualTo(CarbonImmutable::now('UTC'))) {
                    throw new \InvalidArgumentException;
                }
                ApprovedSmsParserRelease::query()->create($record);
            });
        } catch (Throwable) {
            $this->error('The SMS parser release was refused. Check the bounded inputs and signing configuration.');

            return self::FAILURE;
        }

        try {
            $json = json_encode($release['bundle'], JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
        } catch (JsonException) {
            $this->error('The SMS parser release could not be encoded.');

            return self::FAILURE;
        }

        $this->line($json);

        return self::SUCCESS;
    }

    /** @return array{record: array<string, mixed>, bundle: array<string, mixed>} */
    private function release(): array
    {
        $provider = trim((string) $this->argument('provider'));
        $sender = trim((string) $this->argument('sender'));
        $version = filter_var($this->argument('pattern_version'), FILTER_VALIDATE_INT, ['options' => ['min_range' => 1]]);
        $expiresAtInput = (string) $this->argument('expires_at');
        $template = $this->template((string) $this->argument('template'));
        $seed = $this->signingSeed();

        if ($version === false
            || preg_match('/^[A-Z0-9._-]{3,32}$/D', $provider) !== 1
            || preg_match('/^(?:\\+[1-9][0-9]{7,14}|[A-Z0-9]{3,11})$/D', $sender) !== 1) {
            throw new \InvalidArgumentException;
        }

        $expiresAt = $this->timestamp($expiresAtInput);
        $approvedAt = CarbonImmutable::now('UTC')->startOfSecond();
        if ($expiresAt->lessThanOrEqualTo($approvedAt)) {
            throw new \InvalidArgumentException;
        }

        $approvedAtString = $approvedAt->format('Y-m-d\TH:i:s\Z');
        $expiresAtString = $expiresAt->format('Y-m-d\TH:i:s\Z');
        $transcript = $this->transcript([
            '2', $provider, $sender, $template,
            (string) $version, $approvedAtString, $expiresAtString,
        ]);
        $releaseId = hash('sha256', $transcript);
        $keypair = sodium_crypto_sign_seed_keypair($seed);
        $publicKey = sodium_crypto_sign_publickey($keypair);
        $signature = sodium_crypto_sign_detached($transcript, sodium_crypto_sign_secretkey($keypair));
        $release = [
            'schema_version' => 2,
            'provider' => $provider,
            'sender' => $sender,
            'template' => $template,
            'pattern_version' => $version,
            'approved_at' => $approvedAtString,
            'expires_at' => $expiresAtString,
            'signature' => $this->base64Url($signature),
        ];

        return [
            'record' => [
                'release_id' => $releaseId,
                'provider' => $provider,
                'sender' => $sender,
                'template' => $template,
                'pattern_version' => $version,
                'approved_at' => $approvedAtString,
                'expires_at' => $expiresAtString,
                'signature' => $release['signature'],
                'signing_public_key' => $this->base64Url($publicKey),
            ],
            'bundle' => [
                'signing_public_key' => $this->base64Url($publicKey),
                'release' => $release,
            ],
        ];
    }

    private function template(string $template): string
    {
        if (! $this->bounded($template, 512)) {
            throw new \InvalidArgumentException;
        }

        $seen = [];
        $cursor = 0;
        $previousWasField = false;
        while ($cursor < strlen($template)) {
            $open = strpos($template, '{', $cursor);
            $strayClose = strpos($template, '}', $cursor);
            if ($strayClose !== false && ($open === false || $strayClose < $open)) {
                throw new \InvalidArgumentException;
            }
            if ($open === false) {
                break;
            }
            if ($open > $cursor) {
                $previousWasField = false;
            }
            $close = strpos($template, '}', $open + 1);
            if ($close === false) {
                throw new \InvalidArgumentException;
            }
            $field = substr($template, $open, $close - $open + 1);
            if (! in_array($field, self::TEMPLATE_FIELDS, true) || isset($seen[$field]) || $previousWasField) {
                throw new \InvalidArgumentException;
            }
            $seen[$field] = true;
            $previousWasField = true;
            $cursor = $close + 1;
        }
        if (count($seen) !== count(self::TEMPLATE_FIELDS)) {
            throw new \InvalidArgumentException;
        }

        return $template;
    }

    private function signingSeed(): string
    {
        $configured = config('openpay.pairing.enrollment_signing_secret');
        if (! is_string($configured) || preg_match('/^[A-Za-z0-9_-]{43}$/D', $configured) !== 1) {
            throw new \InvalidArgumentException;
        }
        $seed = base64_decode(strtr($configured.'=', '-_', '+/'), true);
        if (! is_string($seed) || strlen($seed) !== SODIUM_CRYPTO_SIGN_SEEDBYTES || $this->base64Url($seed) !== $configured) {
            throw new \InvalidArgumentException;
        }

        return $seed;
    }

    private function timestamp(string $value): CarbonImmutable
    {
        if (preg_match('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/D', $value) !== 1) {
            throw new \InvalidArgumentException;
        }
        $timestamp = CarbonImmutable::createFromFormat('!Y-m-d\TH:i:s\Z', $value, 'UTC');
        if ($timestamp === false || $timestamp->format('Y-m-d\TH:i:s\Z') !== $value) {
            throw new \InvalidArgumentException;
        }

        return $timestamp;
    }

    /** @param list<string> $fields */
    private function transcript(array $fields): string
    {
        $transcript = '';
        foreach (['openpaycongo/operator-payment-pattern', ...$fields] as $field) {
            if (strlen($field) > 65535) {
                throw new \InvalidArgumentException;
            }
            $transcript .= pack('n', strlen($field)).$field;
        }
        if (strlen($transcript) > 8192) {
            throw new \InvalidArgumentException;
        }

        return $transcript;
    }

    private function bounded(string $value, int $maximum): bool
    {
        return $value !== '' && mb_check_encoding($value, 'UTF-8') && mb_strlen($value) <= $maximum && ! preg_match('/[\x00-\x1F\x7F]/', $value);
    }

    private function base64Url(string $value): string
    {
        return rtrim(strtr(base64_encode($value), '+/', '-_'), '=');
    }
}
