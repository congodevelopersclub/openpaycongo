import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('contributor governance packet preserves maintainer authority and public safety', async () => {
  const packet = await readFile(new URL('./contributor-governance-decision.md', import.meta.url), 'utf8');

  for (const section of [
    '## Existing public evidence',
    '## Decisions required from maintainers',
    '## Publication gate',
    '## Triage and release-authority gate',
  ]) {
    assert.match(packet, new RegExp(section.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }

  assert.match(packet, /not yet approved/i);
  assert.match(packet, /does not select/i);
  assert.match(packet, /private contact data/i);
  assert.match(packet, /sign-off/i);
  assert.match(packet, /licensing/i);
  assert.match(packet, /code of conduct/i);
});
