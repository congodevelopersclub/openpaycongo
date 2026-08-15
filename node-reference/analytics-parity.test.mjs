import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { runParity } from './docs/parity-harness.mjs';
import { createAnalyticsFixtureServer } from './server.mjs';

test('Node SQLite analytics fixture satisfies the canonical black-box parity harness', async (t) => {
  const analyticsResponse = JSON.parse(await readFile(new URL('./docs/sales-analytics-response.valid.json', import.meta.url), 'utf8'));
  const fixture = await createAnalyticsFixtureServer({ databasePath: ':memory:', buildVersion: 'fixture-build', analyticsResponse });
  t.after(() => fixture.app.close());

  const report = await runParity({
    name: 'node-sqlite-fixture',
    runtime: 'node',
    datastore: 'sqlite',
    baseURL: fixture.baseURL,
    capabilities: ['analytics'],
    identity: fixture.identity,
    readiness: fixture.readiness,
  });

  assert.deepEqual(report.passed, [
    'operational-healthz',
    'operational-readyz',
    'operational-version',
    'analytics-vector',
    'analytics-conditional',
    'analytics-missing-token',
    'analytics-wrong-scope',
  ]);
  assert.deepEqual(report.skipped, []);
});
