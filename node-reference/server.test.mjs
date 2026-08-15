import assert from 'node:assert/strict';
import test from 'node:test';
import { createOperationalServer } from './server.mjs';

test('Node SQLite reference proves process liveness and closed write admission without claiming analytics', async (t) => {
  const app = await createOperationalServer({ databasePath: ':memory:', buildVersion: 'test-build', contractVersion: 'draft' });
  t.after(() => app.close());

  assert.equal((await app.inject('/healthz')).statusCode, 200);
  const ready = await app.inject('/readyz');
  assert.equal(ready.statusCode, 503);
  assert.equal(ready.headers['cache-control'], 'no-store');
  assert.deepEqual(ready.json(), {
    datastore: 'ok', migration: 'pending', topology: 'unsupported', projection: 'unimplemented', write_admission: 'closed', contract_version: 'draft', migration_revision: 'unimplemented', adapter: 'sqlite', implementation: 'node-reference',
  });
  const version = await app.inject('/version');
  assert.equal(version.headers['cache-control'], 'no-store');
  assert.deepEqual(version.json(), { build: 'test-build', contract_version: 'draft', implementation: 'node-reference', adapter: 'sqlite', migration_revision: 'unimplemented' });
});
