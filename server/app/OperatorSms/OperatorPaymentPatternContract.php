<?php

declare(strict_types=1);

namespace App\OperatorSms;

use InvalidArgumentException;

/** Canonical schema 1 release fields shared by manual review and signing. */
final class OperatorPaymentPatternContract
{
    private const array PAYMENT_FIELDS = ['{amount}', '{currency}', '{reference}'];

    private const array WALLET_FIELDS = ['{amount}', '{currency}', '{reference}', '{customer}', '{occurred_at}'];

    public static function assertFields(string $provider, string $sender, string $template, bool $walletEvidence = false): void
    {
        if (preg_match('/^[A-Z0-9._-]{3,32}$/D', $provider) !== 1
            || preg_match('/^(?:\\+[1-9][0-9]{7,14}|[A-Z0-9]{3,11})$/D', $sender) !== 1
            || ($walletEvidence ? ! self::validWalletTemplate($template) : ! self::validTemplate($template))) {
            throw new InvalidArgumentException('The parser pattern is not valid for the mobile contract.');
        }
    }

    public static function validTemplate(string $template): bool
    {
        $fields = self::templateFields($template);

        return $fields !== null && (self::sameFields($fields, self::PAYMENT_FIELDS) || self::sameFields($fields, self::WALLET_FIELDS));
    }

    public static function validWalletTemplate(string $template): bool
    {
        return self::sameFields(self::templateFields($template) ?? [], self::WALLET_FIELDS);
    }

    /** @return list<string>|null */
    private static function templateFields(string $template): ?array
    {
        if ($template === '' || mb_strlen($template) > 512 || ! mb_check_encoding($template, 'UTF-8')
            || preg_match('/[\x00-\x1F\x7F]/', $template) === 1) {
            return null;
        }

        $seen = [];
        $cursor = 0;
        $previousWasField = false;
        while ($cursor < strlen($template)) {
            $open = strpos($template, '{', $cursor);
            $strayClose = strpos($template, '}', $cursor);
            if ($strayClose !== false && ($open === false || $strayClose < $open)) {
                return null;
            }
            if ($open === false) {
                break;
            }
            if ($open > $cursor) {
                $previousWasField = false;
            }
            $close = strpos($template, '}', $open + 1);
            if ($close === false) {
                return null;
            }
            $field = substr($template, $open, $close - $open + 1);
            if (! in_array($field, self::WALLET_FIELDS, true) || isset($seen[$field]) || $previousWasField) {
                return null;
            }
            $seen[$field] = true;
            $previousWasField = true;
            $cursor = $close + 1;
        }

        return array_keys($seen);
    }

    /** @param list<string> $actual @param list<string> $expected */
    private static function sameFields(array $actual, array $expected): bool
    {
        sort($actual);
        sort($expected);

        return $actual === $expected;
    }

    /** @param array{schema_version: string, provider: string, sender: string, template: string, pattern_version: int, approved_at: string, expires_at: string} $release */
    public static function transcript(array $release): string
    {
        $transcript = '';
        foreach ([
            'openpaycongo/operator-payment-pattern', $release['schema_version'], $release['provider'], $release['sender'],
            $release['template'], (string) $release['pattern_version'], $release['approved_at'], $release['expires_at'],
        ] as $field) {
            if (strlen($field) > 65535) {
                throw new InvalidArgumentException('The signed parser release is too large.');
            }
            $transcript .= pack('n', strlen($field)).$field;
        }

        return $transcript;
    }
}
