import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { ParityFailure, runParity } from './parity-harness.mjs';

const root = new URL('./', import.meta.url);
const expected = JSON.parse(await readFile(new URL('sales-analytics-response.valid.json', root), 'utf8'));
const identity = { build: 'fixture-build', contract_version: '1.0.0-draft', implementation: 'fixture', adapter: 'fixture', migration_revision: '0001' };
const readiness = { datastore: 'ok', migration: 'current', topology: 'supported', projection: 'healthy', write_admission: 'open', contract_version: identity.contract_version, migration_revision: identity.migration_revision, adapter: identity.adapter, implementation: identity.implementation };

async function fixtureTarget({ divergent = false, divergentVersion = false } = {}) {
  const server = createServer((req, res) => {
    if (req.url === '/healthz') return res.end();
    if (req.url === '/readyz') return res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' }).end(JSON.stringify(readiness));
    if (req.url === '/version') return res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' }).end(JSON.stringify(divergentVersion ? { ...identity, adapter: 'wrong' } : identity));
    if (!req.url.startsWith('/v1/analytics/sales?')) return res.writeHead(404).end();
    if (!req.headers.authorization) return res.writeHead(401).end();
    if (req.headers.authorization !== 'Bearer parity-fixture-analytics-read') return res.writeHead(403).end();
    const headers = { 'cache-control': 'private, max-age=30, must-revalidate', vary: 'Authorization', etag: expected.etag };
    if (req.headers['if-none-match'] === expected.etag) return res.writeHead(304, headers).end();
    return res.writeHead(200, { ...headers, 'content-type': 'application/json' }).end(JSON.stringify(divergent ? { ...expected, projection_version: 'bad' } : expected));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  return {
    target: { name: divergent ? 'controlled-divergence' : 'fixture-reference', runtime: 'fixture-node', datastore: 'fixture', baseURL: `http://127.0.0.1:${port}`, capabilities: ['analytics'], identity, readiness },
    close: () => new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve())),
  };
}

test('harness accepts canonical fixture reference over HTTP', async (t) => {
  const fixture = await fixtureTarget();
  t.after(fixture.close);
  const report = await runParity(fixture.target);
  assert.equal(report.runtime, 'fixture-node');
  assert.deepEqual(report.passed, ['operational-healthz', 'operational-readyz', 'operational-version', 'analytics-vector', 'analytics-conditional', 'analytics-missing-token', 'analytics-wrong-scope']);
  assert.deepEqual(report.skipped, []);
});

test('harness identifies controlled divergent response with case and invariant', async (t) => {
  const fixture = await fixtureTarget({ divergent: true });
  t.after(fixture.close);
  await assert.rejects(() => runParity(fixture.target), (error) => error instanceof ParityFailure && error.message.includes('runtime=fixture-node') && error.message.includes('datastore=fixture') && error.message.includes('request=/v1/analytics/sales?') && error.message.includes('analytics-vector: canonical response'));
});

test('harness identifies a divergent operational version identity', async (t) => {
  const fixture = await fixtureTarget({ divergentVersion: true });
  t.after(fixture.close);
  await assert.rejects(() => runParity(fixture.target), (error) => error instanceof ParityFailure && error.message.includes('operational-version: canonical response'));
});

test('targets without capability produce explicit non-parity skip', async (t) => {
  const fixture = await fixtureTarget();
  t.after(fixture.close);
  const report = await runParity({ ...fixture.target, name: 'legacy-go', capabilities: [] });
  assert.deepEqual(report.skipped, [{ case: 'analytics-vector', reason: 'target declares analytics unavailable' }]);
});

test('harness rejects a malformed target manifest before making a request', async () => {
  const valid = { name: 'fixture-reference', runtime: 'fixture-node', datastore: 'fixture', baseURL: 'http://127.0.0.1:1', capabilities: ['analytics'] };
  for (const [target, invariant] of [
    [{ ...valid, name: '' }, 'target name'],
    [{ ...valid, runtime: '' }, 'runtime'],
    [{ ...valid, datastore: '' }, 'datastore'],
    [{ ...valid, baseURL: 'not a URL' }, 'base URL'],
    [{ ...valid, capabilities: ['unknown'] }, 'capabilities'],
  ]) {
    await assert.rejects(
      () => runParity(target),
      (error) => error instanceof ParityFailure && error.message.includes(`target-manifest: ${invariant}`),
    );
  }
});
