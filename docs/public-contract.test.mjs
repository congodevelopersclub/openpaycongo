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

test('delivery workflow is least-privilege, serialized, pinned, and Docker-only', async () => {
  const workflowSource = await readFile(
    resolve(repositoryRoot, '.github/workflows/ci.yml'),
    'utf8',
  );
  const workflow = parse(workflowSource);
  const goDockerfile = await readFile(
    resolve(repositoryRoot, 'wallet-plugin-go/Dockerfile'),
    'utf8',
  );
  const flutterDockerfile = await readFile(
    resolve(repositoryRoot, 'android-client/Dockerfile.ci'),
    'utf8',
  );
  const contractDockerfile = await readFile(
    resolve(repositoryRoot, 'docs/Dockerfile'),
    'utf8',
  );
  const dockerIgnore = await readFile(resolve(repositoryRoot, '.dockerignore'), 'utf8');
  const androidManifest = await readFile(
    resolve(repositoryRoot, 'android-client/android/app/src/main/AndroidManifest.xml'),
    'utf8',
  );
  const androidAppBuild = await readFile(
    resolve(repositoryRoot, 'android-client/android/app/build.gradle'),
    'utf8',
  );

  assert.deepEqual(workflow.permissions, { contents: 'read' });
  assert.ok(workflow.concurrency?.group);
  assert.equal(workflow.concurrency?.['cancel-in-progress'], true);

  for (const jobName of ['contract', 'go', 'flutter', 'admin-browser']) {
    assert.ok(workflow.jobs?.[jobName], `missing ${jobName} job`);
  }

  const actionSteps = Object.values(workflow.jobs)
    .flatMap((job) => job.steps ?? [])
    .filter((step) => step.uses);
  assert.ok(actionSteps.length > 0);
  for (const step of actionSteps) {
    assert.match(
      step.uses,
      /^[^@]+@[a-f0-9]{40}(?:\s+# .+)?$/,
      `${step.uses} must be pinned to a full commit SHA with a version comment`,
    );
  }
  assert.match(
    workflowSource,
    /actions\/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6/,
  );
  assert.match(
    workflowSource,
    /actions\/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7\.0\.1/,
  );

  const runs = Object.values(workflow.jobs)
    .flatMap((job) => job.steps ?? [])
    .map((step) => step.run)
    .filter(Boolean)
    .join('\n');
  assert.match(runs, /docker build --target test -f docs\/Dockerfile \./);
  assert.doesNotMatch(runs, /\/workspace\/docs\/node_modules/);
  assert.match(runs, /docker build[\s\S]*wallet-plugin-go/);
  assert.match(runs, /docker build[\s\S]*android-client/);
  assert.match(runs, /--target test/);
  assert.match(runs, /--target analyze/);
  assert.match(runs, /--target artifact/);
  assert.match(runs, /docker compose -f admin-ui\/compose\.test\.yaml up --build --abort-on-container-exit --exit-code-from browser/);
  assert.match(runs, /docker compose -f admin-ui\/compose\.test\.yaml down --volumes --remove-orphans/);
  const adminSteps = workflow.jobs['admin-browser'].steps ?? [];
  assert.ok(
    adminSteps.some((step) => step.if === 'always()' && /docker compose -f admin-ui\/compose\.test\.yaml down --volumes --remove-orphans/.test(step.run ?? '')),
    'admin browser journey must tear down Compose resources even when the journey fails',
  );
  assert.match(goDockerfile, /go vet \.\/\.\./);
  assert.match(goDockerfile, /go test -race \.\/\.\./);
  assert.match(
    contractDockerfile,
    /FROM node:24\.19\.0-alpine@sha256:2a49bdf71e9fd965a58c1703fd9ddd205b34e5782b692a72dd1d248abb0beb43 AS dependencies/,
  );
  assert.match(contractDockerfile, /COPY docs\/package\.json docs\/package-lock\.json \.\//);
  assert.match(contractDockerfile, /RUN npm ci --ignore-scripts/);
  assert.match(contractDockerfile, /WORKDIR \/workspace[\s\S]*COPY docs\/ \.\/docs\//);
  assert.match(contractDockerfile, /COPY \.dockerignore \/workspace\/\.dockerignore/);
  assert.doesNotMatch(contractDockerfile, /COPY \. \./, 'contract image must not copy the repository wholesale');
  for (const vector of [
    'pairing-signed-qr.vector.json',
    'pairing-key-schedule.vector.json',
    'pairing-protocol.vector.json',
  ]) {
    const source = `wallet-plugin-go/internal/pairing/testdata/${vector}`;
    assert.match(contractDockerfile, new RegExp(`COPY ${source.replaceAll('.', '\\.')} /workspace/${source.replaceAll('.', '\\.')}`));
    assert.match(dockerIgnore, new RegExp(`!${source.replaceAll('.', '\\.')}`));
  }
  assert.doesNotMatch(contractDockerfile, /COPY wallet-plugin-go\/internal\/pairing\/testdata\/\s/, 'contract image must copy vectors individually');
  const analyticsVector = 'wallet-plugin-go/internal/analytics/testdata/sales-analytics.vector.json';
  assert.match(contractDockerfile, new RegExp(`COPY ${analyticsVector.replaceAll('.', '\\.')} /workspace/${analyticsVector.replaceAll('.', '\\.')}`));
  assert.match(dockerIgnore, new RegExp(`!${analyticsVector.replaceAll('.', '\\.')}`));
  assert.doesNotMatch(contractDockerfile, /COPY wallet-plugin-go\/internal\/analytics\/testdata\/\s/, 'contract image must copy analytics vectors individually');
  assert.match(contractDockerfile, /FROM dependencies AS test[\s\S]*RUN npm test/);
  assert.match(flutterDockerfile, /flutter analyze/);
  assert.match(flutterDockerfile, /flutter test/);
  assert.match(flutterDockerfile, /flutter build apk --debug/);
  assert.match(
    flutterDockerfile,
    /FLUTTER_VERSION=3\.44\.9/,
  );
  assert.match(
    flutterDockerfile,
    /FLUTTER_ARCHIVE_SHA256=a9120fa4a01048bdef438ddc3a2d4b7389662ea98a95db86eeaf10382bc4efcb/,
  );
  assert.doesNotMatch(androidManifest, /\bpackage\s*=/);
  assert.match(androidAppBuild, /namespace "com\.congodeveloperclub\.opencongopay"/);
  assert.match(androidAppBuild, /applicationId "com\.congodeveloperclub\.opencongopay"/);
});
