import { createHash } from 'node:crypto';
import Database from 'better-sqlite3';
import Fastify from 'fastify';

const migrationRevision = '0001';
const migrationChecksum = createHash('sha256').update('node-reference-operational-v1').digest('hex');

function migrate(database) {
  database.exec(`
    CREATE TABLE IF NOT EXISTS node_reference_schema_migrations (
      revision TEXT PRIMARY KEY,
      checksum TEXT NOT NULL
    )
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

export async function createOperationalServer({
  databasePath,
  buildVersion = 'dev',
  contractVersion = 'unimplemented',
}) {
  const database = new Database(databasePath, { readonly: false });
  migrate(database);
  const app = Fastify({ logger: false });
  app.addHook('onClose', () => database.close());

  const readiness = {
    datastore: 'ok',
    migration: 'current',
    topology: 'unsupported',
    projection: 'unimplemented',
    write_admission: 'closed',
    contract_version: contractVersion,
    migration_revision: migrationRevision,
    adapter: 'sqlite',
    implementation: 'node-reference',
  };

  app.get('/healthz', async () => ({ status: 'ok' }));
  app.get('/readyz', async (_request, reply) => reply
    .header('cache-control', 'no-store')
    .code(503)
    .send(readiness));
  app.get('/version', async (_request, reply) => reply
    .header('cache-control', 'no-store')
    .send({
      build: buildVersion,
      contract_version: contractVersion,
      implementation: 'node-reference',
      adapter: 'sqlite',
      migration_revision: migrationRevision,
    }));

  return app;
}
