<?php

declare(strict_types=1);

namespace App\Analytics;

use Brick\Math\BigInteger;
use DateTimeImmutable;
use InvalidArgumentException;
use PDO;

final class SqliteAnalyticsStore
{
    public function __construct(private readonly PDO $database)
    {
        $this->database->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $this->database->exec('CREATE TABLE IF NOT EXISTS sales_analytics_events (
            accepted_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            event_id TEXT NOT NULL UNIQUE, tenant_id TEXT NOT NULL, kind TEXT NOT NULL,
            amount_minor TEXT NOT NULL, currency TEXT NOT NULL, provider TEXT NOT NULL,
            payment_id TEXT NOT NULL, related_event_id TEXT NULL, occurred_at TEXT NOT NULL,
            received_at TEXT NOT NULL, payload_digest TEXT NOT NULL
        )');
    }

    /** @param list<array<string, mixed>> $events */
    public function append(array $events): void
    {
        if (count($events) > 100) {
            throw new InvalidArgumentException('event batch exceeds the configured bound');
        }
        $statement = $this->database->prepare('INSERT INTO sales_analytics_events
            (event_id, tenant_id, kind, amount_minor, currency, provider, payment_id, related_event_id, occurred_at, received_at, payload_digest)
            VALUES (:event_id, :tenant_id, :kind, :amount_minor, :currency, :provider, :payment_id, :related_event_id, :occurred_at, :received_at, :payload_digest)');
        $this->database->beginTransaction();
        try {
            foreach ($events as $event) {
                $this->assertMoney($event['amount_minor'] ?? null);
                $this->assertUtc($event['occurred_at'] ?? null, 'occurred_at');
                $this->assertUtc($event['received_at'] ?? null, 'received_at');
                $statement->execute($event + ['related_event_id' => null]);
            }
            $this->database->commit();
        } catch (\Throwable $exception) {
            $this->database->rollBack();
            throw $exception;
        }
    }

    /** @return array{events: list<array<string, string|null>>, next_cursor: string} */
    public function list(string $tenantId, string $snapshotAt, string $cursor = '', int $limit = 100): array
    {
        $this->assertUtc($snapshotAt, 'snapshot_at');
        $sequence = $this->cursor($cursor);
        if ($limit < 1 || $limit > 100) {
            throw new InvalidArgumentException('limit must be between 1 and 100');
        }
        $statement = $this->database->prepare('SELECT accepted_sequence, event_id, tenant_id, kind, amount_minor, currency, provider, payment_id, related_event_id, occurred_at, received_at, payload_digest
            FROM sales_analytics_events WHERE tenant_id = :tenant_id AND accepted_sequence > :cursor AND received_at <= :snapshot_at
            ORDER BY accepted_sequence ASC LIMIT :limit');
        $statement->bindValue(':tenant_id', $tenantId);
        $statement->bindValue(':cursor', $sequence, PDO::PARAM_INT);
        $statement->bindValue(':snapshot_at', $snapshotAt);
        $statement->bindValue(':limit', $limit + 1, PDO::PARAM_INT);
        $statement->execute();
        /** @var list<array<string, string>> $rows */
        $rows = $statement->fetchAll(PDO::FETCH_ASSOC);
        $hasMore = count($rows) > $limit;
        $rows = array_slice($rows, 0, $limit);
        $next = $hasMore ? (string) $rows[array_key_last($rows)]['accepted_sequence'] : '';
        $events = array_map(static function (array $row): array {
            unset($row['accepted_sequence']);

            return $row;
        }, $rows);

        return ['events' => $events, 'next_cursor' => $next];
    }

    /** @return list<array{currency: string, gross_minor: string, refunds_minor: string, net_minor: string, payment_count: string, refund_count: string, average_ticket_minor: string}> */
    public function currencyTotals(string $tenantId, string $from, string $to, string $snapshotAt): array
    {
        $this->assertUtc($from, 'from');
        $this->assertUtc($to, 'to');
        $this->assertUtc($snapshotAt, 'snapshot_at');
        if ($from >= $to) {
            throw new InvalidArgumentException('from must precede to');
        }
        $statement = $this->database->prepare('SELECT event_id, kind, amount_minor, currency, related_event_id
            FROM sales_analytics_events
            WHERE tenant_id = :tenant_id AND occurred_at >= :from AND occurred_at < :to AND received_at <= :snapshot_at
            ORDER BY accepted_sequence ASC');
        $statement->execute(['tenant_id' => $tenantId, 'from' => $from, 'to' => $to, 'snapshot_at' => $snapshotAt]);
        /** @var list<array{event_id: string, kind: string, amount_minor: string, currency: string, related_event_id: string|null}> $events */
        $events = $statement->fetchAll(PDO::FETCH_ASSOC);
        $voided = [];
        foreach ($events as $event) {
            if ($event['kind'] === 'payment_voided') {
                $voided[$event['related_event_id'] ?? ''] = true;
            }
        }
        $totals = [];
        foreach ($events as $event) {
            if ($event['kind'] === 'payment_captured' && ! isset($voided[$event['event_id']])) {
                $totals[$event['currency']] ??= ['gross' => BigInteger::zero(), 'refunds' => BigInteger::zero(), 'payments' => 0, 'refund_count' => 0];
                $totals[$event['currency']]['gross'] = $totals[$event['currency']]['gross']->plus($event['amount_minor']);
                $totals[$event['currency']]['payments']++;
            }
            if ($event['kind'] === 'payment_refunded') {
                $totals[$event['currency']] ??= ['gross' => BigInteger::zero(), 'refunds' => BigInteger::zero(), 'payments' => 0, 'refund_count' => 0];
                $totals[$event['currency']]['refunds'] = $totals[$event['currency']]['refunds']->plus($event['amount_minor']);
                $totals[$event['currency']]['refund_count']++;
            }
        }
        ksort($totals);

        return array_map(static fn (array $total, string $currency): array => [
            'currency' => $currency,
            'gross_minor' => (string) $total['gross'],
            'refunds_minor' => (string) $total['refunds'],
            'net_minor' => (string) $total['gross']->minus($total['refunds']),
            'payment_count' => (string) $total['payments'],
            'refund_count' => (string) $total['refund_count'],
            'average_ticket_minor' => $total['payments'] === 0 ? '0' : (string) $total['gross']->dividedBy($total['payments']),
        ], $totals, array_keys($totals));
    }

    private function assertMoney(mixed $value): void
    {
        if (! is_string($value) || preg_match('/^(0|[1-9][0-9]{0,19})$/D', $value) !== 1) {
            throw new InvalidArgumentException('amount_minor must be a canonical decimal minor-unit string');
        }
    }

    private function assertUtc(mixed $value, string $field): void
    {
        if (! is_string($value) || preg_match('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/D', $value) !== 1 || new DateTimeImmutable($value)->format('Y-m-d\\TH:i:s\\Z') !== $value) {
            throw new InvalidArgumentException($field.' must be a canonical UTC timestamp');
        }
    }

    private function cursor(string $cursor): int
    {
        if ($cursor === '') {
            return 0;
        }
        if (preg_match('/^[1-9][0-9]*$/D', $cursor) !== 1 || filter_var($cursor, FILTER_VALIDATE_INT) === false) {
            throw new InvalidArgumentException('cursor must be a bounded monotonic sequence');
        }

        return (int) $cursor;
    }
}
