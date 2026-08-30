import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import test from 'node:test';
import SwaggerParser from '@apidevtools/swagger-parser';
import Ajv from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import canonicalize from 'canonicalize';
import { createHash } from 'node:crypto';
import { parse } from 'yaml';

const root = new URL('./', import.meta.url);
const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const asset = (relativePath) => new URL(relativePath, root);
const readJson = async (relativePath) => JSON.parse(await readFile(asset(relativePath), 'utf8'));

const dockerInvocationLines = (job) => (job.steps ?? [])
  .flatMap((step) => (step.run ?? '').split('\n'))
  .filter((line) => /\bdocker\b/.test(line));

const postgresClientImages = (job) => {
  const lines = dockerInvocationLines(job);

  for (const line of lines) {
    assert.match(line.trimStart(), /^docker (?:build|run) /, `noncanonical Docker invocation: ${line.trim()}`);
    assert.equal((line.match(/\bdocker\b/g) ?? []).length, 1, `multiple Docker invocations: ${line.trim()}`);
    assert.doesNotMatch(line, /[;&|]/, `chained Docker invocation: ${line.trim()}`);
  }

  return lines
    .filter((line) => line.trimStart().startsWith('docker run '))
  .map((line) => {
    const arguments_ = line.trim().slice('docker run '.length).split(/\s+/);
    let index = 0;

    while (arguments_[index]?.startsWith('--')) {
      const option = arguments_[index++];

      if (option === '--rm') continue;

      if (option === '--network' || option === '--env') {
        assert.notEqual(arguments_[index], undefined, `missing value for ${option}`);
        index++;
        continue;
      }

      assert.fail(`unexpected docker run option: ${option}`);
    }

    const image = arguments_[index];
    assert.notEqual(image, undefined, 'docker run command must name an image');

    return image;
  });
};

const assertPostgresClientImages = (job, expected) => {
  assert.deepEqual(postgresClientImages(job), expected);
};

test('the published sync API and canonical event fixtures are interoperable', async () => {
  const api = await SwaggerParser.validate(asset('openapi.yaml').pathname);
  assert.deepEqual(Object.keys(api.paths).filter((path) => path === '/v1/sync/push'), ['/v1/sync/push']);
  for (const status of ['401', '403', '422']) assert.ok(api.paths['/v1/sync/push'].post.responses[status]);
  assert.ok(api.paths['/readyz'].get.responses['200'].content['application/json'].schema.required.includes('write_admission'));
  assert.ok(api.components.schemas.Problem.required.includes('request_id'));
  const schema = await readJson('ledger-event.schema.json');
  const positive = await readJson('ledger-event.valid.json');
  const negative = await readJson('ledger-event.invalid.json');
  const ajv = new Ajv({ allErrors: true, strict: true });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  assert.equal(validate(positive), true, ajv.errorsText(validate.errors));
  assert.equal(validate(negative), false);
  assert.equal('tenant_id' in positive, false);
  assert.equal(validate({ ...positive, raw_sms: 'forbidden' }), false);
  assert.equal(validate({ ...positive, kind: 'debit' }), false);
  assert.equal(validate({ ...positive, kind: 'debit', expected_wallet_revision: '12' }), true);
  const { payload_digest, ...event } = positive;
  assert.equal(createHash('sha256').update(canonicalize(event), 'utf8').digest('hex'), payload_digest);
});

test('delivery workflow validates contracts, canonical Laravel, and Flutter in Docker', async () => {
  const workflowSource = await readFile(resolve(repositoryRoot, '.github/workflows/ci.yml'), 'utf8');
  const workflow = parse(workflowSource);
  const contractDockerfile = await readFile(resolve(repositoryRoot, 'docs/Dockerfile'), 'utf8');
  const serverDockerfile = await readFile(resolve(repositoryRoot, 'server/Dockerfile'), 'utf8');
  const flutterDockerfile = await readFile(resolve(repositoryRoot, 'android-client/Dockerfile.ci'), 'utf8');
  const readme = await readFile(resolve(repositoryRoot, 'README.md'), 'utf8');

  assert.deepEqual(workflow.permissions, { contents: 'read' });
  assert.ok(workflow.concurrency?.group);
  assert.equal(workflow.concurrency?.['cancel-in-progress'], true);
  assert.deepEqual(Object.keys(workflow.jobs).sort(), ['contract', 'deposit-concurrency', 'flutter', 'laravel', 'postgres-migration']);
  const runs = Object.values(workflow.jobs).flatMap((job) => job.steps ?? []).map((step) => step.run).filter(Boolean).join('\n');
  assert.match(runs, /docker build --target test -f docs\/Dockerfile \./);
  assert.match(runs, /docker build --target test -f server\/Dockerfile \./);
  const postgresImage = 'postgres:16-alpine@sha256:cf78e76683b9ca8c5733cbbdce6c9262b45b6767934dd0a95e671f9a0fc20685';
  assert.equal(workflow.jobs['postgres-migration'].services.postgres.image, postgresImage);
  const expectedPostgresClients = ['openpaycongo-server-postgres', postgresImage, postgresImage];
  assertPostgresClientImages(workflow.jobs['postgres-migration'], expectedPostgresClients);
  assert.throws(() => assertPostgresClientImages({
    steps: [{ run: `docker run --rm ${postgresImage} \\` }, { run: 'docker run --rm postgres:16-alpine \\' }],
  }, expectedPostgresClients), /Expected values to be strictly deep-equal/);
  for (const invocation of [
    `env PGPASSWORD=openpay docker run --rm ${postgresImage} \\`,
    `command docker run --rm ${postgresImage} \\`,
    `if true; then docker run --rm ${postgresImage} \\; fi`,
  ]) {
    assert.throws(() => postgresClientImages({ steps: [{ run: invocation }] }), /noncanonical Docker invocation/);
  }
  for (const invocation of [
    `docker run --rm ${postgresImage} \\; docker run --rm postgres:16-alpine \\`,
    `docker run --rm ${postgresImage} \\ && docker run --rm postgres:16-alpine \\`,
  ]) {
    assert.throws(() => postgresClientImages({ steps: [{ run: invocation }] }), /multiple Docker invocations|chained Docker invocation/);
  }
  assert.match(runs, /deposits_reverses_deposit_id_foreign:FOREIGN KEY/);
  assert.match(runs, /deposits_reverses_deposit_id_unique:UNIQUE/);
  assert.match(runs, /docker build[\s\S]*android-client/);
  assert.doesNotMatch(runs, /competing-runtime/i);
  assert.match(contractDockerfile, /RUN npm test/);
  assert.match(contractDockerfile, /RUN npm ci --ignore-scripts/);
  assert.doesNotMatch(contractDockerfile, /COPY \. \./);
  assert.doesNotMatch(contractDockerfile, /competing-runtime/i);
  assert.match(serverDockerfile, /COPY server\/composer\.json server\/composer\.lock/);
  assert.match(serverDockerfile, /COPY server\/ \.\//);
  assert.match(flutterDockerfile, /flutter test/);
  assert.match(flutterDockerfile, /flutter analyze/);
  assert.match(flutterDockerfile, /flutter build apk --debug/);
  assert.match(readme, /Congo OpenPay Server/);
  assert.match(readme, /server\/Dockerfile/);
  assert.doesNotMatch(readme, /competing-runtime/i);
});
