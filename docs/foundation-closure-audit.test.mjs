import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('foundation closure audit preserves explicit maintainer decisions and evidence-only closure state', async () => {
  const audit = await readFile(new URL('./foundation-closure-audit.md', import.meta.url), 'utf8');

  for (const section of [
    '## Maintainer decision matrix',
    '## Native child closure audit',
    '## Evidence rule',
  ]) {
    assert.match(audit, new RegExp(section.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }

  for (const issue of ['#9', '#38', '#67', '#10', '#69', '#11', '#21', '#68']) assert.match(audit, new RegExp(issue.replace('#', '\\#')));
  assert.match(audit, /do not close/i);
  assert.match(audit, /not yet approved/i);
  assert.match(audit, /Published `SECURITY\.md` policy/);
  assert.match(audit, /private-reporting enablement and exception authority remain pending/i);
  assert.match(audit, /reproducible public evidence/i);
  assert.doesNotMatch(audit, /all children complete/i);
});
