import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import Ajv from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import canonicalize from 'canonicalize';
import YAML from 'yaml';

const root = new URL('./', import.meta.url);
const readJson = async (path) => JSON.parse(await readFile(new URL(path, root), 'utf8'));
const sha256 = (value) => createHash('sha256').update(canonicalize(value), 'utf8').digest('hex');

test('sales analytics vector is portable, bounded, decimal-string only, and DST explicit', async () => {
  const vector = await readJson('sales-analytics.vector.json');
  const ajv = new Ajv({ allErrors: true, strict: true });
  addFormats(ajv);
  const querySchema = await readJson('sales-analytics-query.schema.json');
  const responseSchema = await readJson('sales-analytics-response.schema.json');
  const validateEvent = ajv.compile(await readJson('sales-ledger-event.schema.json'));
  const validateQuery = ajv.compile(querySchema);
  const validateResponse = ajv.compile(responseSchema);
  assert.match(querySchema.properties.snapshot_at.description, /receipt-time cutoff/i);
  assert.ok(responseSchema.properties.action_required.items.properties.kind.enum.includes('lifecycle_conflict'));
  assert.ok(responseSchema.properties.action_required.items.properties.action.enum.includes('review_correction_lifecycle'));
  assert.equal(validateQuery(vector.query), true, JSON.stringify(validateQuery.errors));
  for (const event of vector.events) {
    assert.equal(validateEvent(event), true, JSON.stringify(validateEvent.errors));
    assert.equal(typeof event.amount_minor, 'string');
    const { payload_digest: suppliedDigest, ...canonicalEvent } = event;
    assert.equal(sha256(canonicalEvent), suppliedDigest, `event ${event.event_id} digest is not canonical`);
  }
  for (const invalidTimestamp of ['2026-11-01T04:00:00.000Z', '2026-11-01T04:00:00+00:00']) {
    assert.equal(validateQuery({ ...vector.query, from: invalidTimestamp }), false, `accepted non-canonical timestamp ${invalidTimestamp}`);
  }
  assert.deepEqual(vector.expected.series_boundaries, [['2026-11-01T04:00:00Z', '2026-11-02T05:00:00Z']], 'fall-back day must remain one 25-hour local-day bucket');
  assert.deepEqual(vector.expected.current_currencies.map(({ currency }) => currency), ['CDF', 'USD']);
  assert.equal(vector.expected.current_currencies.some(({ gross_minor }) => typeof gross_minor !== 'string'), false);
  const response = await readJson('sales-analytics-response.valid.json');
  assert.equal(validateResponse(response), true, JSON.stringify(validateResponse.errors));
  assert.equal(response.projection_version, vector.expected.projection_version);
  assert.equal(response.etag, vector.expected.etag);
  const { etag: suppliedETag, ...canonicalResponse } = response;
  assert.equal(`"${sha256(canonicalResponse)}"`, suppliedETag, 'ETag must cover the complete canonical response except etag');
});

test('sales analytics OpenAPI and PRD preserve tenant, readiness, cache, rebuild, and bounds truth', async () => {
  const api = YAML.parse(await readFile(new URL('openapi.yaml', root), 'utf8'));
  const operation = api.paths['/v1/analytics/sales']?.get;
  assert.ok(operation, 'missing analytics query operation');
  assert.deepEqual(operation.security, [
    { AdministratorOAuth: ['analytics:read'] },
    { MobileOAuth: ['analytics:read'] },
    { MerchantOAuth: ['analytics:read'] },
  ]);
  assert.deepEqual(operation.parameters.filter(({ in: location }) => location === 'query').map(({ name }) => name).sort(), ['comparison', 'from', 'interval', 'snapshot_at', 'time_zone', 'to']);
  assert.equal(operation.parameters.filter(({ in: location }) => location === 'query').every(({ required }) => required === true), true);
  assert.equal(operation.responses['200'].content['application/json'].schema.$ref, './sales-analytics-response.schema.json');
  assert.equal(operation.responses['200'].headers.ETag.required, true);
  assert.match(operation.responses['200'].headers['Cache-Control'].schema.const, /private/);
  const prd = await readFile(new URL('prd-backend.md', root), 'utf8');
  for (const required of ['immutable canonical ledger', 'no floating point', 'atomic\\s+projection\\s+replacement', 'out-of-order', 'America/New_York', '10,000', '93 days', 'analytics:read', 'lifecycle_conflict', 'receipt-time cutoff']) assert.match(prd, new RegExp(required, 'i'));
});
