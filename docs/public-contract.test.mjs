import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import SwaggerParser from '@apidevtools/swagger-parser';
import Ajv from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import canonicalize from 'canonicalize';
import { createHash } from 'node:crypto';

const root = new URL('./', import.meta.url);
const asset = (relativePath) => new URL(relativePath, root);
const readJson = async (relativePath) => JSON.parse(await readFile(asset(relativePath), 'utf8'));
const digest = (event) => {
  const { payload_digest, ...publicEvent } = event;
  return createHash('sha256').update(canonicalize(publicEvent), 'utf8').digest('hex');
};

test('the published sync API and canonical event fixtures are interoperable', async () => {
  const api = await SwaggerParser.validate(asset('openapi.yaml').pathname);
  assert.deepEqual(Object.keys(api.paths).filter((path) => path === '/v1/sync/push'), ['/v1/sync/push'], 'v1 publishes one push route');
  for (const status of ['401', '403', '422']) assert.ok(api.paths['/v1/sync/push'].post.responses[status], `push publishes ${status}`);
  assert.ok(api.paths['/readyz'].get.responses['200'].content['application/json'].schema.required.includes('write_admission'));
  assert.ok(api.paths['/readyz'].get.responses['503'].content['application/json'].schema.required.includes('write_admission'));
  assert.ok(api.components.schemas.Problem.required.includes('code'));
  assert.ok(api.components.schemas.Problem.required.includes('request_id'));

  const schema = await readJson('ledger-event.schema.json');
  const positive = await readJson('ledger-event.valid.json');
  const negative = await readJson('ledger-event.invalid.json');
  const ajv = new Ajv({ allErrors: true, strict: true });
  addFormats(ajv);
  const validate = ajv.compile(schema);

  assert.equal(validate(positive), true, ajv.errorsText(validate.errors));
  assert.equal(validate(negative), false, 'the invalid public fixture must be rejected');
  assert.equal(validate({ ...positive, raw_sms: 'forbidden' }), false, 'raw SMS alone is rejected');
  assert.equal('tenant_id' in positive, false, 'tenant identity must be derived from authentication, not payload');
  assert.equal(positive.payload_digest, '5fb6ce005c30c2ad8bedd13ce54d194db9c2e59292e0646f4cfd90c932513a42', 'fixture is a published JCS digest vector');
  assert.equal(digest(positive), positive.payload_digest, 'payload digest covers the JCS public event excluding itself');

  const alteredAmount = { ...positive, amount_minor: '687001' };
  assert.notEqual(digest(alteredAmount), positive.payload_digest, 'a modified payload must not retain the original digest');
  assert.equal(validate({ ...positive, tenant_id: 'forbidden' }), false, 'tenant_id must be rejected from public input');
  assert.equal(validate({ ...positive, device_sequence: 42 }), false, 'device sequence must remain a decimal string');
  assert.equal(validate({ ...positive, kind: 'debit' }), false, 'debits require an expected wallet revision');
  assert.equal(validate({ ...positive, kind: 'debit', expected_wallet_revision: '12' }), true, 'a debit carries a decimal wallet revision');
});
