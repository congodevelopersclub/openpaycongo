const money = /^(0|[1-9][0-9]{0,19})$/;
const timestamp = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;

const canonicalTimestamp = (value, field) => {
  if (typeof value !== 'string' || !timestamp.test(value) || Number.isNaN(Date.parse(value))) throw new Error(`${field} must be a canonical UTC timestamp`);
  return value;
};

const cursorValue = (cursor) => {
  if (cursor === '') return 0;
  if (typeof cursor !== 'string' || !/^[1-9][0-9]*$/.test(cursor) || !Number.isSafeInteger(Number(cursor))) throw new Error('cursor must be a bounded monotonic sequence');
  return Number(cursor);
};

export function createAnalyticsStore(database) {
  database.exec(`CREATE TABLE IF NOT EXISTS sales_analytics_events (
    accepted_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id TEXT NOT NULL UNIQUE,
    tenant_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    amount_minor TEXT NOT NULL,
    currency TEXT NOT NULL,
    provider TEXT NOT NULL,
    payment_id TEXT NOT NULL,
    related_event_id TEXT,
    occurred_at TEXT NOT NULL,
    received_at TEXT NOT NULL,
    payload_digest TEXT NOT NULL
  )`);
  const insert = database.prepare(`INSERT INTO sales_analytics_events
    (event_id, tenant_id, kind, amount_minor, currency, provider, payment_id, related_event_id, occurred_at, received_at, payload_digest)
    VALUES (@event_id, @tenant_id, @kind, @amount_minor, @currency, @provider, @payment_id, @related_event_id, @occurred_at, @received_at, @payload_digest)`);

  return {
    append(events) {
      const append = database.transaction((values) => values.forEach((event) => {
        if (typeof event.amount_minor !== 'string' || !money.test(event.amount_minor)) throw new Error('amount_minor must be a canonical decimal minor-unit string');
        canonicalTimestamp(event.occurred_at, 'occurred_at');
        canonicalTimestamp(event.received_at, 'received_at');
        insert.run({ ...event, related_event_id: event.related_event_id ?? null });
      }));
      append(events);
    },
    list({ tenantID, snapshotAt, cursor = '', limit = 100 }) {
      canonicalTimestamp(snapshotAt, 'snapshot_at');
      const sequence = cursorValue(cursor);
      if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw new Error('limit must be between 1 and 100');
      const rows = database.prepare(`SELECT accepted_sequence, event_id, tenant_id, kind, amount_minor, currency, provider, payment_id, related_event_id, occurred_at, received_at, payload_digest
        FROM sales_analytics_events
        WHERE tenant_id = ? AND accepted_sequence > ? AND received_at <= ?
        ORDER BY accepted_sequence ASC LIMIT ?`).all(tenantID, sequence, snapshotAt, limit + 1);
      const hasMore = rows.length > limit;
      const events = rows.slice(0, limit).map(({ accepted_sequence, ...event }) => event);
      return { events, nextCursor: hasMore ? String(rows[limit - 1].accepted_sequence) : '' };
    },
  };
}
