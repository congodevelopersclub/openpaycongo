import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import test from 'node:test';
import SwaggerParser from '@apidevtools/swagger-parser';
import Ajv from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const docsRoot = new URL('./', import.meta.url);
const repositoryRoot = resolve(fileURLToPath(docsRoot), '..');
const read = (name) => readFile(new URL(name, docsRoot), 'utf8');

test('canonical contract validates its OpenAPI, synthetic fixtures, and Laravel routes', async () => {
  const api = await SwaggerParser.validate(fileURLToPath(new URL('openapi.yaml', docsRoot)));
  const ajv = new Ajv({ allErrors: true, strict: true });
  addFormats(ajv);
  const validateDeposit = ajv.compile(api.components.schemas.MobileDepositRequest);
  const validDeposit = JSON.parse(await read('mobile-deposit.valid.json'));
  const invalidDeposit = JSON.parse(await read('mobile-deposit.invalid.json'));

  assert.equal(validateDeposit(validDeposit), true, ajv.errorsText(validateDeposit.errors));
  assert.equal(validateDeposit(invalidDeposit), false);
  assert.deepEqual(api.paths['/oauth/token'].post.requestBody.content['application/x-www-form-urlencoded'].schema.required, ['grant_type', 'client_id', 'client_secret']);
  assert.deepEqual(api.paths['/mobile/deposits'].post.responses['201'].content['application/json'].schema.required, ['outcome']);
  assert.deepEqual(api.paths['/services/identity'].get.security, [{ DeveloperOAuth: ['payment-requests:read'] }]);
  assert.ok(api.paths['/v1/sync/pull'].get);
  assert.equal(api.paths['/v1/sync/pull'].get['x-openpay-status'], 'planned');

  const routes = await readFile(resolve(repositoryRoot, 'server/routes/api.php'), 'utf8');
  for (const path of ['/oauth/token', '/mobile/deposits', '/mobile/envelopes', '/services/identity', '/v1/pairing/complete']) {
    assert.match(routes, new RegExp(`['"]${path.replaceAll('/', '\\/')}['"]`), `Laravel route missing from inventory: ${path}`);
    assert.ok(api.paths[path], `OpenAPI path missing Laravel route: ${path}`);
  }
});

test('documentation states the Laravel and Flutter implementation boundary without legacy runtimes', async () => {
  const contract = await read('canonical-contract.md');
  const mobileReadme = await readFile(resolve(repositoryRoot, 'android-client/README.md'), 'utf8');

  assert.match(contract, /server\/routes\/api\.php/);
  assert.match(contract, /android-client\/README\.md/);
  assert.match(contract, /synthetic/i);
  assert.match(contract, /customers:pii:read/);
  assert.match(contract, /cursor-based/i);
  assert.match(contract, /deprecated|deprecation/i);
  assert.match(mobileReadme, /contract-only/);
  assert.match(mobileReadme, /No canonical .*sync.*client/i);
  assert.doesNotMatch(contract, /removed (?:Go|Node) runtime/i);
});
