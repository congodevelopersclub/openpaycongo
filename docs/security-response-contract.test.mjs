import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import test from 'node:test';

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const read = (path) => readFile(resolve(repositoryRoot, path), 'utf8');

test('security response policy is private, accountable, and release-blocking', async () => {
  const security = await read('SECURITY.md');

  for (const heading of [
    '## Private reporting',
    '## Supported versions',
    '## Severity and release decisions',
    '## Ownership and response targets',
    '## Coordinated disclosure',
    '## Emergency release procedure',
    '## Regression and threat-model rules',
  ]) {
    assert.match(security, new RegExp(heading.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }

  assert.match(security, /private vulnerability reporting is currently disabled/i);
  assert.match(security, /No production-supported release currently exists/i);
  assert.match(security, /Production release \| Not available/i);
  assert.match(security, /Main branch and pull-request artifacts \| Not supported/i);
  assert.match(security, /Do not publish/i);
  assert.match(security, /Critical findings are release blockers/i);
  assert.match(security, /High findings are release blockers/i);
  assert.match(security, /provisional severe/i);
  assert.match(security, /pauses promotion of an\s+affected candidate/i);
  assert.match(security, /repository credential, signing key, protected release identity/i);
  assert.match(security, /revoke or rotate the credential/i);
  assert.match(security, /rebuild from a restored trust root/i);
  assert.match(security, /two business days/i);
  assert.match(security, /seven calendar\s+days/i);
  assert.match(security, /regression test/i);
  assert.match(security, /trust-boundary/i);
});

test('private-report tabletop fixture is synthetic and excludes sensitive content', async () => {
  const fixture = await read('docs/security-report-tabletop.fixture.md');

  assert.match(fixture, /SYNTHETIC TABLETOP ONLY/);
  assert.match(fixture, /SYNTHETIC-REPORT-001/);
  assert.match(fixture, /private report/i);
  assert.match(fixture, /regression test/i);
  assert.match(fixture, /advisory draft/i);
  assert.match(fixture, /patched-release decision/i);
  assert.match(fixture, /No real user, customer, credential, token, key, raw SMS, exploit\s+payload, or topology detail/i);
  assert.doesNotMatch(fixture, /(@|ghp_|github_pat_|AKIA|-----BEGIN|password\s*[:=])/i);
});
