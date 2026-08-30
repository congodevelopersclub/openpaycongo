import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import test from 'node:test';

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const read = (path) => readFile(resolve(repositoryRoot, path), 'utf8');

const requiredTabletopFields = [
  /# SYNTHETIC TABLETOP ONLY: private-report lifecycle/,
  /Private report identifier: `SYNTHETIC-REPORT-001`/,
  /Affected component: `example\.invalid\/synthetic-component`/,
  /Reporter contact: withheld in this public fixture/,
  /Claim: a synthetic authorization boundary needs review/,
  /Evidence: a non-executable, synthetic reproduction summary only/,
  /private report → fix → regression test →\s*advisory draft → patched-release decision/,
];

const sensitiveTabletopFields = [
  /^\s*(?:raw\s+sms|sms\s+body)\s*:/im,
  /^\s*(?:phone(?:\s+number)?|customer\s+name|customer\s+reference)\s*:/im,
  /^\s*(?:payment\s+(?:amount|reference)|account\s+(?:number|balance))\s*:/im,
  /^\s*(?:authorization|bearer|jwt|access\s+token)\s*:/im,
  /^\s*(?:internal\s+(?:host|url)|topology|private\s+(?:ip|endpoint))\s*:/im,
];

function assertSyntheticTabletop(fixture) {
  for (const field of requiredTabletopFields) assert.match(fixture, field);
  for (const field of sensitiveTabletopFields) {
    assert.doesNotMatch(fixture, field, `synthetic tabletop contains a prohibited field: ${field}`);
  }
}

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

  assertSyntheticTabletop(fixture);
  assert.match(fixture, /private report/i);
  assert.match(fixture, /regression test/i);
  assert.match(fixture, /advisory draft/i);
  assert.match(fixture, /patched-release decision/i);
  assert.match(fixture, /No real user, customer, credential, token, key, raw SMS, exploit\s+payload, or topology detail/i);
  assert.doesNotMatch(fixture, /(@|ghp_|github_pat_|AKIA|-----BEGIN|password\s*[:=])/i);

  const mutations = [
    'Raw SMS: synthetic message text',
    'Phone number: +243000000000',
    'Customer name: Synthetic Customer',
    'Payment amount: 123',
    'Authorization: Bearer synthetic-token-value',
    'JWT: synthetic-token-value',
    'Internal host: 10.0.0.1',
  ];

  for (const mutation of mutations) {
    assert.throws(
      () => assertSyntheticTabletop(`${fixture}\n${mutation}\n`),
      /synthetic tabletop contains a prohibited field/,
      `fixture mutation must be rejected: ${mutation}`,
    );
  }
});
