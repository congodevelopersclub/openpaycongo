import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import test from 'node:test';

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const read = (path) => readFile(resolve(repositoryRoot, path), 'utf8');

const tabletopSource = {
  fixture: 'SYNTHETIC-REPORT-001',
  component: 'example.invalid/synthetic-component',
  reporterContact: 'withheld',
  claim: 'a synthetic authorization boundary needs review',
  evidence: 'non-executable, synthetic reproduction summary',
  steps: [
    'acknowledge_and_freeze',
    'reproduce_and_block',
    'fix_and_regression',
    'draft_advisory',
    'record_release_decision',
    'coordinate_disclosure',
  ],
};

function renderTabletop(source) {
  return `# SYNTHETIC TABLETOP ONLY: private-report lifecycle

This fixture exercises the process without creating a real report, advisory,
or release. No real user, customer, credential, token, key, raw SMS, exploit
payload, or topology detail appears here. Do not submit this fixture to GitHub
or copy it into a report.

## Input

- Private report identifier: \`${source.fixture}\`
- Affected component: \`${source.component}\`
- Reporter contact: withheld in this public fixture
- Claim: ${source.claim}
- Evidence: a ${source.evidence} only

## Tabletop path

1. A triage owner acknowledges the private report within two business days,
   assigns provisional severe classification, freezes the synthetic candidate,
   and records neither report details nor a public disclosure.
2. The triage and release owners reproduce the synthetic claim with safe
   evidence and decide the affected artifact is a release blocker for this
   tabletop.
3. A maintainer prepares the smallest synthetic fix and a regression test that
   proves the boundary. The regression test contains no exploit payload.
4. The coordinator prepares a private advisory draft with affected and patched
   synthetic versions, mitigation, reporter credit preference, and links the
   synthetic fix and regression-test evidence from step 3.
5. The release owner records a patched-release decision after Docker-backed
   tests and scans identify the synthetic artifact.
6. The group agrees a coordinated disclosure date, then records the
   post-incident learning: update the threat model if the boundary or residual
   risk changed.

## Expected result

The exercise proves the sequence **private report → fix → regression test →
advisory draft → patched-release decision**. It creates no real advisory,
release, customer record, secret, or security finding.
`;
}

function assertClosedWorldTabletop(source, markdown) {
  assert.deepEqual(source, tabletopSource, 'tabletop JSON must contain only the approved synthetic schema and values');
  assert.equal(markdown.replaceAll('\r\n', '\n'), renderTabletop(source), 'Markdown fixture must be the deterministic rendering of the closed-world JSON source');
}

function parseCanonicalTabletop(rawSource) {
  const canonicalSource = JSON.stringify(tabletopSource, null, 2) + '\n';

  assert.equal(
    rawSource.replaceAll('\r\n', '\n'),
    canonicalSource,
    'tabletop JSON must use the canonical closed-world serialization',
  );

  return JSON.parse(rawSource);
}

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
  /^\s*(?:(?:[-*+]\s*)|(?:\d+[.)]\s*))?(?:raw\s+sms|sms\s+body)\s*:/im,
  /^\s*(?:(?:[-*+]\s*)|(?:\d+[.)]\s*))?(?:phone(?:\s+number)?|customer\s+name|customer\s+reference)\s*:/im,
  /^\s*(?:(?:[-*+]\s*)|(?:\d+[.)]\s*))?(?:payment\s+(?:amount|reference)|account\s+(?:number|balance))\s*:/im,
  /^\s*(?:(?:[-*+]\s*)|(?:\d+[.)]\s*))?(?:authorization|bearer|jwt|access(?:\s+|_)token)\s*:/im,
  /^\s*(?:(?:[-*+]\s*)|(?:\d+[.)]\s*))?(?:api(?:\s+|_)key|client(?:\s+|_)secret|refresh(?:\s+|_)token|password)\s*:/im,
  /^\s*(?:(?:[-*+]\s*)|(?:\d+[.)]\s*))?(?:internal(?:\s+|_)(?:host|url)|topology|private(?:\s+|_)(?:ip|endpoint))\s*:/im,
  /\b(?:raw\s+sms|sms\s+body)\b\s+(?:is|was|contains)\b/i,
  /\b(?:phone(?:\s+number)?|customer\s+(?:name|reference)|payment\s+(?:amount|reference)|account\s+(?:number|balance))\b\s+(?:is|was|equals)\b/i,
  /\b(?:authorization|bearer|jwt|access(?:\s+|_)token)\b\s+(?:is|was)\b/i,
  /\b(?:api(?:\s+|_)key|client(?:\s+|_)secret|refresh(?:\s+|_)token|password)\b\s+(?:is|was|equals|contains)\b/i,
  /\b(?:api(?:\s+|_)key|client(?:\s+|_)secret|refresh(?:\s+|_)token|access(?:\s+|_)token|password)\s*=\s*[^\s&#"'<>]+/i,
  /\b(?:internal(?:\s+|_)(?:host|url)|topology|private(?:\s+|_)(?:ip|endpoint))\b\s+(?:is|was)\b/i,
  /\+\d{7,15}\b/,
  /\b(?:10|127)\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/,
  /\b192\.168\.\d{1,3}\.\d{1,3}\b/,
  /\b172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b/,
  /\b169\.254\.\d{1,3}\.\d{1,3}\b/,
  /\[(?:::1|fe[89ab][0-9a-f:]*|f[cd][0-9a-f:]*)\]/i,
  /\bsk_(?:live|test)_[A-Za-z0-9_-]+\b/i,
];

function plainSafetyText(markdown) {
  return markdown
    .replace(/\[([^\]\n]+)\]\([^\)\n]*\)/g, '$1')
    .replace(/<[^>\n]*>/g, '')
    .replaceAll('\\_', '_')
    .replaceAll('\\*', '*')
    .replaceAll('\\`', '`')
    .replace(/_([^_\n]+):_/g, '$1:')
    .replace(/[`*]/g, '');
}

function assertSyntheticTabletop(fixture) {
  assertClosedWorldTabletop(tabletopSource, fixture);
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
  assert.match(security, /GitHub public issues are permitted only for a sanitized report/i);
  assert.match(security, /Use the bug-report template/i);
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
  assert.match(security, /verifying ordinary release authority—or, if step 3 invoked the compromise\s+response/i);
  const rollbackCheckpoint = security.indexOf('For immediate containment, the release owner may authorize a rollback before');
  const remediationCheckpoint = security.indexOf('The release owner prepares the smallest remediation');
  const advisoryCheckpoint = security.indexOf('After the artifact evidence is available, the incident coordinator prepares');
  const authorizationCheckpoint = security.indexOf('The release owner authorizes the patched release only after');
  assert.ok(rollbackCheckpoint >= 0, 'emergency procedure must retain a rollback path before a patch exists');
  assert.ok(remediationCheckpoint >= 0, 'emergency procedure must prepare a remediation explicitly');
  assert.ok(rollbackCheckpoint < remediationCheckpoint, 'immediate rollback must precede patch remediation');
  const rollbackStep = security.slice(rollbackCheckpoint, remediationCheckpoint);
  assert.match(rollbackStep, /identifying the rollback artifact, recording why it\s+predates the affected artifact and contains the incident/i);
  assert.match(rollbackStep, /verifying\s+ordinary release authority—or restored authority if step 3 invoked the\s+compromise response/i);
  assert.match(rollbackStep, /rollback decision and user\s+communication in the private record/i);
  assert.ok(advisoryCheckpoint >= 0, 'emergency procedure must create a private advisory after artifact evidence');
  assert.ok(authorizationCheckpoint >= 0, 'emergency procedure must authorize a release explicitly');
  assert.ok(remediationCheckpoint < advisoryCheckpoint, 'patch-only advisory gates must follow remediation');
  assert.ok(advisoryCheckpoint < authorizationCheckpoint, 'private advisory, fix/regression links, and release date must precede authorization');
  assert.match(security, /private advisory draft, links the fix and minimal regression evidence,\s+and the release owner records the patched-release date/i);
  assert.match(security, /two business days/i);
  assert.match(security, /seven calendar\s+days/i);
  assert.match(security, /regression test/i);
  assert.match(security, /trust-boundary/i);
});

test('private-report tabletop fixture is synthetic, closed-world, and rendered deterministically', async () => {
  const fixture = await read('docs/security-report-tabletop.fixture.md');
  const rawSource = await read('docs/security-report-tabletop.fixture.json');
  const source = parseCanonicalTabletop(rawSource);

  assertClosedWorldTabletop(source, fixture);
  assert.match(fixture, /private report/i);
  assert.match(fixture, /regression test/i);
  assert.match(fixture, /advisory draft/i);
  assert.match(fixture, /patched-release decision/i);
  assert.match(fixture, /No real user, customer, credential, token, key, raw SMS, exploit\s+payload, or topology detail/i);
  assert.doesNotMatch(fixture, /(@|ghp_|github_pat_|AKIA|-----BEGIN|password\s*[:=])/i);

  const mutations = [
    '- Raw SMS: synthetic message text',
    '- **Raw SMS:** synthetic bold-label message text',
    '- *Raw SMS:* synthetic italic-label message text',
    '- _Raw SMS:_ synthetic underscore-label message text',
    '- `Raw SMS:` synthetic code-label message text',
    '- <strong>Raw SMS:</strong> synthetic HTML-label message text',
    '1. Raw SMS: synthetic numbered-list message text',
    '1) Raw SMS: synthetic parenthesized-list message text',
    '- Phone number: +243000000000',
    '- Customer name: Synthetic Customer',
    '- Payment amount: 123',
    '- Authorization: Bearer synthetic-token-value',
    '- JWT: synthetic-token-value',
    '- API key: sk_live_example',
    '- api_key: sk_live_REALVALUE',
    '- api\\_key: synthetic-secret-value',
    '- client secret: synthetic-client-secret-value',
    '- client_secret: synthetic-client-secret-value',
    '- refresh token: synthetic-refresh-token-value',
    '- access_token: synthetic-access-token-value',
    '[admin](https://example.invalid/?client_secret=REALVALUE)',
    '&lt;a href="https://example.invalid/?access_token=REALVALUE"&gt;admin&lt;/a&gt;',
    'The password is synthetic-password-value.',
    '- Internal host: 10.0.0.1',
    '- internal_host: prod-db.corp.internal',
    'The raw SMS body contains synthetic message text.',
    'The phone number is +243000000000.',
    'The customer name is Synthetic Customer.',
    'The payment amount is 123.',
    'The authorization is Bearer synthetic-token-value.',
    'The internal host is 10.0.0.1.',
    'Connect to http://172.16.0.1/admin for the synthetic topology.',
    'Connect to http://169.254.169.254/latest/meta-data for the synthetic topology.',
    'Connect to http://[::1]/admin for the synthetic topology.',
    'Connect to http://[fe80::1]/admin for the synthetic topology.',
    'Connect to http://[fd00::1]/admin for the synthetic topology.',
    '[admin](http://10.0.0.1/private)',
    '&lt;a href="http://10.0.0.1/private"&gt;admin&lt;/a&gt;',
  ];

  for (const mutation of mutations) {
    assert.throws(
      () => assertSyntheticTabletop(`${fixture}\n${mutation}\n`),
      /Markdown fixture|closed-world/,
      `fixture mutation must be rejected: ${mutation}`,
    );
  }

  assert.throws(() => assertClosedWorldTabletop({ ...source, unknown: 'freeform prose' }, fixture));
  assert.throws(() => assertClosedWorldTabletop({ ...source, claim: 'https://example.invalid/?access_token=REALVALUE' }, fixture));
  assert.throws(() => assertClosedWorldTabletop(source, `${fixture}\nextra prose`));
  assert.throws(
    () => parseCanonicalTabletop(rawSource.replace(
      '  "claim": "a synthetic authorization boundary needs review",',
      '  "claim": "unsafe first duplicate value",\n  "claim": "a synthetic authorization boundary needs review",',
    )),
    /canonical closed-world serialization/,
    'duplicate JSON keys must not be accepted through JSON.parse last-value semantics',
  );
  assert.doesNotThrow(() => assertClosedWorldTabletop(source, fixture.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n')));
});
