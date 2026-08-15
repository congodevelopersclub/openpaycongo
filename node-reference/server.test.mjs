import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { loadCanonicalAnalyticsFixtures } from './fixture-loader.mjs';
import { createOperationalServer } from './server.mjs';

test('Node SQLite reference exposes operational status while analytics and writes stay closed', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'openpaycongo-node-reference-'));
  const app = await createOperationalServer({
    databasePath: join(directory, 'reference.sqlite'),
    buildVersion: 'test-build',
    contractVersion: 'draft',
  });
  t.after(async () => {
    await app.close();
    await rm(directory, { recursive: true, force: true });
  });

  assert.deepEqual((await app.inject('/healthz')).json(), { status: 'ok' });
  const ready = await app.inject('/readyz');
  assert.equal(ready.statusCode, 503);
  assert.equal(ready.headers['cache-control'], 'no-store');
  assert.deepEqual(ready.json(), {
    datastore: 'ok', migration: 'current', topology: 'unsupported', projection: 'unimplemented',
    write_admission: 'closed', contract_version: 'draft', migration_revision: '0001',
    adapter: 'sqlite', implementation: 'node-reference',
  });
  assert.deepEqual((await app.inject('/version')).json(), {
    build: 'test-build', contract_version: 'draft', implementation: 'node-reference',
    adapter: 'sqlite', migration_revision: '0001',
  });
  assert.equal((await app.inject('/v1/analytics/sales')).statusCode, 404);
  assert.equal((await app.inject({ method: 'POST', url: '/v1/events' })).statusCode, 404);
});

test('canonical analytics fixtures are loaded for internal conformance tests only', async () => {
  const { vector, response } = await loadCanonicalAnalyticsFixtures();
  assert.equal(vector.contract_version, 'sales-analytics-v1');
  assert.match(vector.query.from, /Z$/);
  assert.match(vector.query.to, /Z$/);
  assert.equal(typeof response.current.currencies[0].gross_minor, 'string');
});
