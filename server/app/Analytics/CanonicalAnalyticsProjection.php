<?php

declare(strict_types=1);

namespace App\Analytics;

use Brick\Math\BigInteger;
use DateInterval;
use DateTimeImmutable;
use DateTimeZone;

/** Internal fixture-conformance projection; it intentionally has no HTTP route. */
final class CanonicalAnalyticsProjection
{
    public function __construct(private readonly SqliteAnalyticsStore $store) {}

    /** @param array{from:string,to:string,snapshot_at:string,time_zone:string,interval:string,comparison:bool} $query */
    public function project(string $tenantId, array $query, string $observedAt): array
    {
        $events = $this->store->list($tenantId, $query['snapshot_at'], '', 100)['events'];
        $state = $this->derive($events);
        $currentMetrics = $this->window($state, $query['from'], $query['to']);
        $current = ['from' => $query['from'], 'to' => $query['to'], ...$currentMetrics];
        $duration = (new DateTimeImmutable($query['to']))->getTimestamp() - (new DateTimeImmutable($query['from']))->getTimestamp();
        $comparisonFrom = (new DateTimeImmutable($query['from']))->sub(new DateInterval('PT'.$duration.'S'))->format('Y-m-d\\TH:i:s\\Z');
        $comparison = ['from' => $comparisonFrom, 'to' => $query['from'], ...$this->window($state, $comparisonFrom, $query['from'])];
        $series = [];
        foreach ($this->buckets($query) as [$from, $to]) {
            $series[] = ['from' => $from, 'to' => $to, ...$this->window($state, $from, $to)];
        }
        $sync = $this->sync($events, $observedAt);
        $result = [
            'contract_version' => 'sales-analytics-v1',
            'projection_version' => $this->version($events),
            'readiness' => 'ready',
            'tenant_id' => $tenantId,
            'snapshot_at' => $query['snapshot_at'],
            'observed_at' => $observedAt,
            'time_zone' => $query['time_zone'],
            'current' => $current,
            'comparison' => $query['comparison'] ? $comparison : null,
            'series' => $series,
            'reconciliation' => $this->reconciliation($state, $query['from'], $query['to'], $query['snapshot_at']),
            'sync' => $sync,
            'action_required' => $this->cues($state, $query['from'], $query['to'], $query['snapshot_at'], $sync),
        ];
        if (!$query['comparison']) unset($result['comparison']);
        $result['etag'] = '"'.hash('sha256', json_encode($this->canonical($result), JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)).'"';
        return $result;
    }

    /** @param list<array<string,string|null>> $events */
    private function derive(array $events): array
    {
        $captures = [];
        foreach ($events as $event) if ($event['kind'] === 'payment_captured') $captures[$event['event_id']] = $event;
        $refunds = []; $voided = []; $reconciled = [];
        foreach ($events as $event) {
            $related = $event['related_event_id'] ?? '';
            if (!isset($captures[$related])) continue;
            $capture = $captures[$related];
            if ($event['occurred_at'] < $capture['occurred_at'] || $event['currency'] !== $capture['currency'] || $event['provider'] !== $capture['provider']) continue;
            if ($event['kind'] === 'payment_voided' && $event['amount_minor'] === $capture['amount_minor']) $voided[$related] = true;
            if ($event['kind'] === 'payment_refunded') $refunds[] = $event;
            if ($event['kind'] === 'payment_reconciled' && (!isset($reconciled[$related]) || $event['received_at'] < $reconciled[$related]['received_at'])) $reconciled[$related] = $event;
        }
        return compact('events', 'captures', 'refunds', 'voided', 'reconciled');
    }

    private function window(array $state, string $from, string $to): array
    {
        $currencies = []; $providers = [];
        $add = static function (array &$bucket, string $currency, string $amount, bool $refund): void {
            $bucket[$currency] ??= ['gross' => BigInteger::zero(), 'refunds' => BigInteger::zero(), 'payments' => 0, 'refund_count' => 0];
            if ($refund) { $bucket[$currency]['refunds'] = $bucket[$currency]['refunds']->plus($amount); $bucket[$currency]['refund_count']++; }
            else { $bucket[$currency]['gross'] = $bucket[$currency]['gross']->plus($amount); $bucket[$currency]['payments']++; }
        };
        foreach ($state['captures'] as $id => $event) if (!isset($state['voided'][$id]) && $event['occurred_at'] >= $from && $event['occurred_at'] < $to) {
            $add($currencies, $event['currency'], $event['amount_minor'], false);
            $providers[$event['provider']] ??= []; $add($providers[$event['provider']], $event['currency'], $event['amount_minor'], false);
        }
        foreach ($state['refunds'] as $event) if ($event['occurred_at'] >= $from && $event['occurred_at'] < $to) {
            $add($currencies, $event['currency'], $event['amount_minor'], true);
            $providers[$event['provider']] ??= []; $add($providers[$event['provider']], $event['currency'], $event['amount_minor'], true);
        }
        ksort($currencies); ksort($providers);
        return ['currencies' => $this->render($currencies), 'providers' => array_map(fn (array $values, string $provider) => ['provider' => $provider, 'currencies' => $this->render($values)], $providers, array_keys($providers))];
    }

    private function render(array $values): array
    {
        ksort($values);
        return array_map(static fn (array $value, string $currency) => [
            'currency' => $currency, 'gross_minor' => (string) $value['gross'], 'refunds_minor' => (string) $value['refunds'],
            'net_minor' => (string) $value['gross']->minus($value['refunds']), 'payment_count' => (string) $value['payments'], 'refund_count' => (string) $value['refund_count'],
            'average_ticket_minor' => $value['payments'] === 0 ? '0' : (string) $value['gross']->dividedBy($value['payments']),
        ], $values, array_keys($values));
    }

    private function reconciliation(array $state, string $from, string $to, string $snapshotAt): array
    {
        $max = 0; $unreconciled = 0;
        foreach ($state['captures'] as $id => $capture) if (!isset($state['voided'][$id]) && $capture['occurred_at'] >= $from && $capture['occurred_at'] < $to) {
            $end = $state['reconciled'][$id]['received_at'] ?? $snapshotAt;
            if (!isset($state['reconciled'][$id])) $unreconciled++;
            $max = max($max, (new DateTimeImmutable($end))->getTimestamp() - (new DateTimeImmutable($capture['received_at']))->getTimestamp());
        }
        return ['lag_seconds_max' => (string) max(0, $max), 'unreconciled_count' => (string) $unreconciled];
    }

    private function sync(array $events, string $observedAt): array
    {
        if ($events === []) return ['status' => 'no_events'];
        $watermark = max(array_column($events, 'received_at'));
        $seconds = max(0, (new DateTimeImmutable($observedAt))->getTimestamp() - (new DateTimeImmutable($watermark))->getTimestamp());
        return ['status' => $seconds > 900 ? 'stale' : 'fresh', 'last_received_at' => $watermark, 'freshness_seconds' => (string) $seconds];
    }

    private function cues(array $state, string $from, string $to, string $snapshotAt, array $sync): array
    {
        $late = 0; foreach ($state['events'] as $event) if ($event['occurred_at'] >= $from && $event['occurred_at'] < $to && (new DateTimeImmutable($event['received_at']))->getTimestamp() - (new DateTimeImmutable($event['occurred_at']))->getTimestamp() > 3600) $late++;
        $overdue = 0; foreach ($state['captures'] as $id => $capture) if (!isset($state['voided'][$id]) && !isset($state['reconciled'][$id]) && $capture['occurred_at'] >= $from && $capture['occurred_at'] < $to && (new DateTimeImmutable($snapshotAt))->getTimestamp() - (new DateTimeImmutable($capture['received_at']))->getTimestamp() > 86400) $overdue++;
        $result = []; if ($late) $result[] = ['kind' => 'late_arrival', 'count' => (string) $late, 'action' => 'review_offline_sync']; if ($overdue) $result[] = ['kind' => 'reconciliation_overdue', 'count' => (string) $overdue, 'action' => 'reconcile_provider']; if ($sync['status'] === 'stale') $result[] = ['kind' => 'stale_sync', 'count' => '1', 'action' => 'check_replica_sync'];
        usort($result, static fn (array $left, array $right) => $left['kind'] <=> $right['kind']); return $result;
    }

    private function version(array $events): string { usort($events, static fn (array $left, array $right) => $left['event_id'] <=> $right['event_id']); return hash('sha256', implode('', array_map(static fn (array $event) => $event['event_id'].hex2bin($event['payload_digest']), $events))); }
    private function buckets(array $query): array { $zone = new DateTimeZone($query['time_zone']); $from = new DateTimeImmutable($query['from']); $local = $from->setTimezone($zone); $next = $query['interval'] === 'hour' ? $from->add(new DateInterval('PT1H')) : (new DateTimeImmutable($local->format('Y-m-d').' 00:00:00', $zone))->add(new DateInterval('P1D'))->setTimezone(new DateTimeZone('UTC')); return [[$query['from'], min($next->format('Y-m-d\\TH:i:s\\Z'), $query['to'])]]; }

    private function canonical(mixed $value): mixed
    {
        if (!is_array($value)) return $value;
        $value = array_map($this->canonical(...), $value);
        if (!array_is_list($value)) ksort($value);
        return $value;
    }
}
