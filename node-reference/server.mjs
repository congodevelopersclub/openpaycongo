import Database from 'better-sqlite3';
import Fastify from 'fastify';

export async function createOperationalServer({ databasePath, buildVersion = 'dev', contractVersion = 'unimplemented' }) {
  const database = new Database(databasePath, { readonly: false });
  database.prepare('SELECT 1').get();
  const app = Fastify({ logger: false });
  app.addHook('onClose', () => database.close());
  const readiness = { datastore: 'ok', migration: 'pending', topology: 'unsupported', projection: 'unimplemented', write_admission: 'closed', contract_version: contractVersion, migration_revision: 'unimplemented', adapter: 'sqlite', implementation: 'node-reference' };
  app.get('/healthz', async () => ({ status: 'ok' }));
  app.get('/readyz', async (_request, reply) => reply.header('cache-control', 'no-store').code(503).send(readiness));
  app.get('/version', async (_request, reply) => reply.header('cache-control', 'no-store').send({ build: buildVersion, contract_version: contractVersion, implementation: 'node-reference', adapter: 'sqlite', migration_revision: 'unimplemented' }));
  return app;
}
