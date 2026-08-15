import { createHash } from 'node:crypto';
import Database from 'better-sqlite3';

const migrationRevision = '0002';
const migrationChecksum = createHash('sha256').update('node-reference-pairing-v1').digest('hex');

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
  `);

  const existing = database
    .prepare('SELECT checksum FROM node_reference_schema_migrations WHERE revision = ?')
    .get(migrationRevision);
  if (existing && existing.checksum !== migrationChecksum) {
    throw new Error(`node reference migration checksum drift for ${migrationRevision}`);
  }
  if (!existing) {
    database
      .prepare('INSERT INTO node_reference_schema_migrations (revision, checksum) VALUES (?, ?)')
      .run(migrationRevision, migrationChecksum);
  }
}

function sameIssue(record, pairing) {
  return record.device_id === pairing.deviceId
    && record.checksum === pairing.checksum
    && record.version === pairing.version;
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
}
