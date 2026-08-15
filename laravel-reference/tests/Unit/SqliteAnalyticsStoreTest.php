<?php

declare(strict_types=1);

namespace Tests\Unit;

use App\Analytics\SqliteAnalyticsStore;
use InvalidArgumentException;
use PDO;
use Tests\TestCase;

final class SqliteAnalyticsStoreTest extends TestCase
{
    public function test_canonical_fixture_events_are_paged_by_monotonic_cursor_without_losing_money_or_utc_time(): void
    {
        $fixture = json_decode((string) file_get_contents(base_path('../docs/sales-analytics.vector.json')), true, flags: JSON_THROW_ON_ERROR);
        $store = new SqliteAnalyticsStore(new PDO('sqlite::memory:'));
        $store->append($fixture['events']);

        $first = $store->list('tenant-demo', $fixture['query']['snapshot_at'], '', 2);
        self::assertSame('2', $first['next_cursor']);
        self::assertSame(['4000', '10000'], array_column($first['events'], 'amount_minor'));
        self::assertSame(['2026-10-31T16:00:00Z', '2026-11-01T05:30:00Z'], array_column($first['events'], 'occurred_at'));
        self::assertSame('4', $store->list('tenant-demo', $fixture['query']['snapshot_at'], '2', 2)['next_cursor']);
    }

    public function test_malformed_cursor_is_rejected_before_querying(): void
    {
        $store = new SqliteAnalyticsStore(new PDO('sqlite::memory:'));
        $this->expectException(InvalidArgumentException::class);
        $store->list('tenant-demo', '2026-11-02T12:00:00Z', '2; DROP TABLE sales_analytics_events');
    }

    public function test_event_ingestion_budget_rejects_oversized_batches_before_writing(): void
    {
        $fixture = json_decode((string) file_get_contents(base_path('../docs/sales-analytics.vector.json')), true, flags: JSON_THROW_ON_ERROR);
        $store = new SqliteAnalyticsStore(new PDO('sqlite::memory:'));
        $events = array_fill(0, 101, $fixture['events'][0]);

        $this->expectException(InvalidArgumentException::class);
        $store->append($events);
    }

    public function test_snapshot_bounded_projection_derives_canonical_currency_totals(): void
    {
        $vector = json_decode((string) file_get_contents(base_path('../docs/sales-analytics.vector.json')), true, flags: JSON_THROW_ON_ERROR);
        $response = json_decode((string) file_get_contents(base_path('../docs/sales-analytics-response.valid.json')), true, flags: JSON_THROW_ON_ERROR);
        $store = new SqliteAnalyticsStore(new PDO('sqlite::memory:'));
        $store->append($vector['events']);

        self::assertSame(
            $response['current']['currencies'],
            $store->currencyTotals('tenant-demo', $response['current']['from'], $response['current']['to'], $vector['query']['snapshot_at']),
        );
    }
}
