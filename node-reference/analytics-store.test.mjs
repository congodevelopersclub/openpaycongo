import assert from 'node:assert/strict';
import Database from 'better-sqlite3';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { createAnalyticsStore } from './analytics-store.mjs';

const vector = JSON.parse(await readFile(new URL('./docs/sales-analytics.vector.json', import.meta.url), 'utf8'));

test('SQLite analytics seam preserves canonical money, UTC time, and cursor ordering', () => {
  const database = new Database(':memory:');
  const store = createAnalyticsStore(database);
  store.append(vector.events);

  const first = store.list({ tenantID: 'tenant-demo', snapshotAt: vector.query.snapshot_at, cursor: '', limit: 2 });
  assert.deepEqual(first.events.map(({ event_id, amount_minor, occurred_at }) => ({ event_id, amount_minor, occurred_at })), [
    { event_id: '018f0000-0000-7000-8000-000000000001', amount_minor: '4000', occurred_at: '2026-10-31T16:00:00Z' },
    { event_id: '018f0000-0000-7000-8000-000000000002', amount_minor: '10000', occurred_at: '2026-11-01T05:30:00Z' },
  ]);
  assert.equal(first.nextCursor, '2');

  const second = store.list({ tenantID: 'tenant-demo', snapshotAt: vector.query.snapshot_at, cursor: first.nextCursor, limit: 2 });
  assert.deepEqual(second.events.map((event) => event.event_id), [
    '018f0000-0000-7000-8000-000000000003',
    '018f0000-0000-7000-8000-000000000004',
  ]);
  assert.equal(second.nextCursor, '4');
  assert.throws(() => store.list({ tenantID: 'tenant-demo', snapshotAt: vector.query.snapshot_at, cursor: '2; drop table events', limit: 2 }), /cursor/);
  assert.throws(() => store.append([{ ...vector.events[0], amount_minor: '04' }]), /amount_minor/);
  assert.throws(() => store.append([{ ...vector.events[0], occurred_at: '2026-11-01 05:30:00Z' }]), /occurred_at/);
  database.close();
});
