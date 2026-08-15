import { createHash } from 'node:crypto';
import Database from 'better-sqlite3';

const migrations = [
  ['0002', createHash('sha256').update('node-reference-pairing-v1').digest('hex')],
  ['0003', createHash('sha256').update('node-reference-pairing-sync-v1').digest('hex')],
];
const maxBatchEvents = 100;
const maxPayloadBytes = 8_192;

function migrate(database) {
  database.exec(`
    CREATE TABLE IF NOT EXISTS node_reference_schema_migrations (
      revision TEXT PRIMARY KEY,
      checksum TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS pairing_intents (
      tenant_id TEXT NOT NULL,
      intent_id TEXT NOT NULL,
      device_id TEXT NOT NULL,
      checksum TEXT NOT NULL,
      version TEXT NOT NULL,
      state TEXT NOT NULL CHECK(state IN ('issued', 'completed', 'active')),
      completion_digest TEXT,
      activation_digest TEXT,
      PRIMARY KEY (tenant_id, intent_id)
    );
    CREATE TABLE IF NOT EXISTS sync_batches (
      tenant_id TEXT NOT NULL,
      device_id TEXT NOT NULL,
      idempotency_key TEXT NOT NULL,
      digest TEXT NOT NULL,
      acknowledgement INTEGER NOT NULL,
      PRIMARY KEY (tenant_id, device_id, idempotency_key)
    );
    CREATE TABLE IF NOT EXISTS sync_events (
      tenant_id TEXT NOT NULL,
      device_id TEXT NOT NULL,
      sequence INTEGER NOT NULL,
      event_id TEXT NOT NULL,
      payload_digest TEXT NOT NULL,
      payload TEXT NOT NULL,
      PRIMARY KEY (tenant_id, device_id, sequence),
      UNIQUE (tenant_id, device_id, event_id)
    );
    CREATE TABLE IF NOT EXISTS sync_acknowledgements (
      tenant_id TEXT NOT NULL,
      device_id TEXT NOT NULL,
      acknowledgement INTEGER NOT NULL,
      PRIMARY KEY (tenant_id, device_id)
    );
  `);

  for (const [revision, checksum] of migrations) {
    const existing = database
      .prepare('SELECT checksum FROM node_reference_schema_migrations WHERE revision = ?')
      .get(revision);
    if (existing && existing.checksum !== checksum) {
      throw new Error(`node reference migration checksum drift for ${revision}`);
    }
    if (!existing) {
      database
        .prepare('INSERT INTO node_reference_schema_migrations (revision, checksum) VALUES (?, ?)')
        .run(revision, checksum);
    }
  }
}

function sameIssue(record, pairing) {
  return record.device_id === pairing.deviceId
    && record.checksum === pairing.checksum
    && record.version === pairing.version;
}

function canonicalize(value) {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return value;
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new Error('sync payload must be JSON-safe');
    return value;
  }
  if (Array.isArray(value)) return value.map(canonicalize);
  if (typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonicalize(value[key])]));
  }
  throw new Error('sync payload must be JSON-safe');
}

function normalizeEvents(events) {
  if (!Array.isArray(events) || events.length === 0 || events.length > maxBatchEvents) {
    throw new Error(`sync batch must be bounded to 1-${maxBatchEvents} events`);
  }

  const sequences = new Set();
  const eventIds = new Set();
  return events.map((event) => {
    if (!Number.isSafeInteger(event?.sequence) || event.sequence < 1 || typeof event.eventId !== 'string' || event.eventId.length === 0 || event.eventId.length > 128) {
      throw new Error('sync event is invalid');
    }
    if (sequences.has(event.sequence) || eventIds.has(event.eventId)) throw new Error('sync batch contains duplicate events');
    sequences.add(event.sequence);
    eventIds.add(event.eventId);
    const payload = JSON.stringify(canonicalize(event.payload));
    if (Buffer.byteLength(payload, 'utf8') > maxPayloadBytes) throw new Error('sync event payload exceeds bounded size');
    return {
      sequence: event.sequence,
      eventId: event.eventId,
      payload,
      payloadDigest: createHash('sha256').update(payload).digest('hex'),
    };
  });
}

export class SqlitePairingRepository {
  constructor({ databasePath }) {
    this.database = new Database(databasePath, { readonly: false });
    migrate(this.database);
  }

  close() {
    if (this.database.open) this.database.close();
  }

  issue(pairing) {
    const existing = this.database
      .prepare('SELECT * FROM pairing_intents WHERE tenant_id = ? AND intent_id = ?')
      .get(pairing.tenantId, pairing.intentId);
    if (existing) {
      if (!sameIssue(existing, pairing)) throw new Error('pairing issue conflicts with existing intent');
      return { status: existing.state, replayed: true };
    }

    this.database.prepare(`
      INSERT INTO pairing_intents (tenant_id, intent_id, device_id, checksum, version, state)
      VALUES (?, ?, ?, ?, ?, 'issued')
    `).run(pairing.tenantId, pairing.intentId, pairing.deviceId, pairing.checksum, pairing.version);
    return { status: 'issued', replayed: false };
  }

  complete({ tenantId, intentId, deviceId, checksum, version, completionDigest }) {
    return this.database.transaction(() => {
      const record = this.database
        .prepare('SELECT * FROM pairing_intents WHERE tenant_id = ? AND intent_id = ?')
        .get(tenantId, intentId);
      if (!record) {
        const anyTenant = this.database.prepare('SELECT 1 FROM pairing_intents WHERE intent_id = ?').get(intentId);
        if (anyTenant) throw new Error('pairing tenant scope mismatch');
        throw new Error('pairing unavailable');
      }
      if (record.device_id !== deviceId) throw new Error('pairing device scope mismatch');
      if (record.checksum !== checksum || record.version !== version) throw new Error('pairing contract guard mismatch');
      if (record.state === 'completed' || record.state === 'active') {
        if (record.completion_digest !== completionDigest) throw new Error('pairing completion conflicts with existing completion');
        return { status: record.state === 'active' ? 'active' : 'completed', replayed: true };
      }

      this.database.prepare(`
        UPDATE pairing_intents
        SET state = 'completed', completion_digest = ?
        WHERE tenant_id = ? AND intent_id = ? AND state = 'issued'
      `).run(completionDigest, tenantId, intentId);
      return { status: 'completed', replayed: false };
    })();
  }

  activate({ tenantId, intentId, deviceId, checksum, version, activationDigest }) {
    return this.database.transaction(() => {
      const record = this.database
        .prepare('SELECT * FROM pairing_intents WHERE tenant_id = ? AND intent_id = ?')
        .get(tenantId, intentId);
      if (!record || record.state === 'issued') throw new Error('pairing unavailable');
      if (record.device_id !== deviceId) throw new Error('pairing device scope mismatch');
      if (record.checksum !== checksum || record.version !== version) throw new Error('pairing contract guard mismatch');
      if (record.state === 'active') {
        if (record.activation_digest !== activationDigest) throw new Error('pairing activation conflicts with existing activation');
        return { status: 'active', replayed: true };
      }

      this.database.prepare(`
        UPDATE pairing_intents
        SET state = 'active', activation_digest = ?
        WHERE tenant_id = ? AND intent_id = ? AND state = 'completed'
      `).run(activationDigest, tenantId, intentId);
      return { status: 'active', replayed: false };
    })();
  }

  sync({ tenantId, deviceId, idempotencyKey, events }) {
    return this.database.transaction(() => {
      const activated = this.database.prepare(`
        SELECT 1 FROM pairing_intents WHERE tenant_id = ? AND device_id = ? AND state = 'active'
      `).get(tenantId, deviceId);
      if (!activated) throw new Error('device is not activated for sync');
      if (typeof idempotencyKey !== 'string' || idempotencyKey.length === 0 || idempotencyKey.length > 128) {
        throw new Error('sync idempotency key is invalid');
      }

      const normalizedEvents = normalizeEvents(events);
      const digest = createHash('sha256').update(JSON.stringify(normalizedEvents)).digest('hex');
      const existingBatch = this.database.prepare(`
        SELECT digest, acknowledgement FROM sync_batches
        WHERE tenant_id = ? AND device_id = ? AND idempotency_key = ?
      `).get(tenantId, deviceId, idempotencyKey);
      if (existingBatch) {
        if (existingBatch.digest !== digest) throw new Error('sync batch conflicts with idempotency key');
        return { acknowledgement: existingBatch.acknowledgement, replayed: true };
      }

      const findSequence = this.database.prepare(`
        SELECT event_id, payload_digest FROM sync_events
        WHERE tenant_id = ? AND device_id = ? AND sequence = ?
      `);
      const findEventId = this.database.prepare(`
        SELECT sequence FROM sync_events WHERE tenant_id = ? AND device_id = ? AND event_id = ?
      `);
      const insertEvent = this.database.prepare(`
        INSERT INTO sync_events (tenant_id, device_id, sequence, event_id, payload_digest, payload)
        VALUES (?, ?, ?, ?, ?, ?)
      `);
      for (const event of normalizedEvents) {
        if (findSequence.get(tenantId, deviceId, event.sequence) || findEventId.get(tenantId, deviceId, event.eventId)) {
          throw new Error('sync event conflicts with immutable history');
        }
        insertEvent.run(tenantId, deviceId, event.sequence, event.eventId, event.payloadDigest, event.payload);
      }

      const acknowledgementRow = this.database.prepare(`
        SELECT acknowledgement FROM sync_acknowledgements WHERE tenant_id = ? AND device_id = ?
      `).get(tenantId, deviceId);
      let acknowledgement = acknowledgementRow?.acknowledgement ?? 0;
      const sequences = this.database.prepare(`
        SELECT sequence FROM sync_events
        WHERE tenant_id = ? AND device_id = ? AND sequence > ? ORDER BY sequence
      `).all(tenantId, deviceId, acknowledgement);
      for (const { sequence } of sequences) {
        if (sequence !== acknowledgement + 1) break;
        acknowledgement = sequence;
      }
      this.database.prepare(`
        INSERT INTO sync_acknowledgements (tenant_id, device_id, acknowledgement) VALUES (?, ?, ?)
        ON CONFLICT(tenant_id, device_id) DO UPDATE SET acknowledgement = excluded.acknowledgement
      `).run(tenantId, deviceId, acknowledgement);
      this.database.prepare(`
        INSERT INTO sync_batches (tenant_id, device_id, idempotency_key, digest, acknowledgement)
        VALUES (?, ?, ?, ?, ?)
      `).run(tenantId, deviceId, idempotencyKey, digest, acknowledgement);
      return { acknowledgement, replayed: false };
    })();
  }
}
