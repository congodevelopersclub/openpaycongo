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

// This is a conformance fixture, not a production analytics implementation.
// It proves the Node/Fastify/SQLite HTTP boundary can satisfy the shared
// fixture when a future implementation owns authentication and projection.
export async function createAnalyticsFixtureServer({ databasePath, buildVersion = 'fixture-build', analyticsResponse }) {
  const database = new Database(databasePath, { readonly: false });
  database.prepare('SELECT 1').get();
  const app = Fastify({ logger: false });
  app.addHook('onClose', () => database.close());
  const identity = { build: buildVersion, contract_version: 'sales-analytics-v1', implementation: 'node-sqlite-fixture', adapter: 'sqlite', migration_revision: 'fixture' };
  const readiness = { datastore: 'ok', migration: 'current', topology: 'supported', projection: 'healthy', write_admission: 'closed', contract_version: identity.contract_version, migration_revision: identity.migration_revision, adapter: identity.adapter, implementation: identity.implementation };
  const etag = analyticsResponse.etag;

  app.get('/healthz', async () => ({ status: 'ok' }));
  app.get('/readyz', async (_request, reply) => reply.header('cache-control', 'no-store').send(readiness));
  app.get('/version', async (_request, reply) => reply.header('cache-control', 'no-store').send(identity));
  app.get('/v1/analytics/sales', async (request, reply) => {
    if (!request.headers.authorization) return reply.code(401).send();
    if (request.headers.authorization !== 'Bearer parity-fixture-analytics-read') return reply.code(403).send();
    reply.header('cache-control', 'private, max-age=30, must-revalidate').header('vary', 'Authorization').header('etag', etag);
    if (request.headers['if-none-match'] === etag) return reply.code(304).send();
    return reply.send(analyticsResponse);
  });

  const baseURL = await app.listen({ port: 0, host: '127.0.0.1' });
  return { app, baseURL, identity, readiness };
}
