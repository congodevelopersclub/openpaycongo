import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const root = new URL('./', import.meta.url);
const readJSON = async (path) => JSON.parse(await readFile(new URL(path, root), 'utf8'));

export class ParityFailure extends Error {
  constructor(target, caseID, invariant, detail) {
    super(`${target}: ${caseID}: ${invariant}: ${detail}`);
    this.name = 'ParityFailure';
  }
}

const request = async (target, path, headers = {}) => {
  const response = await fetch(new URL(path, target.baseURL), { headers });
  const body = await response.text();
  return { response, body };
};

const expect = (target, caseID, invariant, actual, expected) => {
  try {
    assert.deepEqual(actual, expected);
  } catch {
    throw new ParityFailure(target.name, caseID, invariant, `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
};

const json = (target, caseID, body) => {
  try {
    return JSON.parse(body);
  } catch {
    throw new ParityFailure(target.name, caseID, 'JSON response', 'invalid JSON');
  }
};

const validateTarget = (target) => {
  if (typeof target?.name !== 'string' || target.name.length === 0) {
    throw new ParityFailure('unnamed-target', 'target-manifest', 'target name', 'must be a non-empty string');
  }
  const name = target.name;
  if (typeof target?.datastore !== 'string' || target.datastore.length === 0) {
    throw new ParityFailure(name, 'target-manifest', 'datastore', 'must be a non-empty string');
  }
  if (!Array.isArray(target.capabilities) || target.capabilities.some((capability) => capability !== 'analytics')) {
    throw new ParityFailure(name, 'target-manifest', 'capabilities', 'must contain only known capabilities');
  }
  let baseURL;
  try {
    baseURL = new URL(target.baseURL);
  } catch {
    throw new ParityFailure(name, 'target-manifest', 'base URL', 'must be an absolute HTTP URL');
  }
  if (!['http:', 'https:'].includes(baseURL.protocol)) {
    throw new ParityFailure(name, 'target-manifest', 'base URL', 'must be an absolute HTTP URL');
  }
  return { ...target, name, baseURL: baseURL.href };
};

export async function runParity(target) {
  target = validateTarget(target);
  const vector = await readJSON('sales-analytics.vector.json');
  const expected = await readJSON('sales-analytics-response.valid.json');
  const query = new URLSearchParams({ ...vector.query, comparison: String(vector.query.comparison) });
  const analyticsPath = `/v1/analytics/sales?${query}`;
  const report = { target: target.name, datastore: target.datastore, passed: [], skipped: [] };

  const health = await request(target, '/healthz');
  expect(target, 'operational-healthz', 'liveness status', health.response.status, 200);
  report.passed.push('operational-healthz');

  const readiness = await request(target, '/readyz');
  expect(target, 'operational-readyz', 'status', readiness.response.status, 200);
  expect(target, 'operational-readyz', 'cache-control', readiness.response.headers.get('cache-control'), 'no-store');
  expect(target, 'operational-readyz', 'canonical response', json(target, 'operational-readyz', readiness.body), target.readiness);
  report.passed.push('operational-readyz');

  const version = await request(target, '/version');
  expect(target, 'operational-version', 'status', version.response.status, 200);
  expect(target, 'operational-version', 'cache-control', version.response.headers.get('cache-control'), 'no-store');
  expect(target, 'operational-version', 'canonical response', json(target, 'operational-version', version.body), target.identity);
  report.passed.push('operational-version');

  if (!target.capabilities.includes('analytics')) {
    report.skipped.push({ case: 'analytics-vector', reason: 'target declares analytics unavailable' });
    return report;
  }

  const headers = { Authorization: 'Bearer parity-fixture-analytics-read' };
  const analytics = await request(target, analyticsPath, headers);
  expect(target, 'analytics-vector', 'status', analytics.response.status, 200);
  expect(target, 'analytics-vector', 'cache-control', analytics.response.headers.get('cache-control'), 'private, max-age=30, must-revalidate');
  expect(target, 'analytics-vector', 'vary', analytics.response.headers.get('vary'), 'Authorization');
  expect(target, 'analytics-vector', 'etag', analytics.response.headers.get('etag'), expected.etag);
  const body = json(target, 'analytics-vector', analytics.body);
  expect(target, 'analytics-vector', 'canonical response', body, expected);
  report.passed.push('analytics-vector');

  const conditional = await request(target, analyticsPath, { ...headers, 'If-None-Match': expected.etag });
  expect(target, 'analytics-conditional', 'status', conditional.response.status, 304);
  expect(target, 'analytics-conditional', 'body', conditional.body, '');
  expect(target, 'analytics-conditional', 'etag', conditional.response.headers.get('etag'), expected.etag);
  report.passed.push('analytics-conditional');
  for (const [caseID, authHeaders, status] of [
    ['analytics-missing-token', {}, 401],
    ['analytics-wrong-scope', { Authorization: 'Bearer parity-fixture-wrong-scope' }, 403],
  ]) {
    const result = await request(target, analyticsPath, authHeaders);
    expect(target, caseID, 'status', result.response.status, status);
    report.passed.push(caseID);
  }
  return report;
}
