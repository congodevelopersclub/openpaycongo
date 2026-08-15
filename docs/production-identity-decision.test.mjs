import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('production identity packet keeps issuer and token authority with maintainers', async () => {
  const packet = await readFile(new URL('./production-identity-decision.md', import.meta.url), 'utf8');

  for (const section of [
    '## Repository evidence',
    '## Decisions required from maintainers',
    '## Claim-matrix decision gate',
    '## Token-lifecycle decision gate',
    '## Fixture and adapter gate',
  ]) {
    assert.match(packet, new RegExp(section.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }

  assert.match(packet, /not yet approved/i);
  assert.match(packet, /does not select/i);
  assert.match(packet, /wrong issuer/i);
  assert.match(packet, /wrong audience/i);
  assert.match(packet, /expired/i);
  assert.match(packet, /redact/i);
  assert.doesNotMatch(packet, /issuer:\s*https?:/i);
});
