import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('release protection packet distinguishes repository evidence from administrator decisions', async () => {
  const packet = await readFile(new URL('./release-protection-decision.md', import.meta.url), 'utf8');

  for (const section of [
    '## Repository evidence',
    '## Administrator decisions required',
    '## Read-only audit gate',
    '## Immutable-release gate',
    '## Emergency and compromise gate',
  ]) {
    assert.match(packet, new RegExp(section.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }

  assert.match(packet, /not yet approved/i);
  assert.match(packet, /read-only/i);
  assert.match(packet, /does not change/i);
  assert.match(packet, /immutable/i);
  assert.match(packet, /post-incident/i);
  assert.doesNotMatch(packet, /approved bypass identity/i);
});
