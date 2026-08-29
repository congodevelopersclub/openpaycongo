import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('./', import.meta.url);

test('threat model separates verified repository facts from pending maintainer authority', async () => {
  const model = await readFile(new URL('threat-model.md', root), 'utf8');

  for (const heading of ['## Verified repository facts', '## Assets, actors, and trust boundaries', '## Abuse cases and current controls', '## Privacy lifecycle', '## Pending maintainer authority']) {
    assert.match(model, new RegExp(heading.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
  assert.match(model, /Raw SMS remains local/i);
  assert.match(model, /tenant_id.*derived from authenticated/i);
  assert.match(model, /Prototype warning.*Laravel server/i);
  assert.match(model, /legacy Flutter.*encryption/i);
  assert.match(model, /simultaneous device and server loss/i);
  assert.match(model, /not production-ready/i);
  assert.match(model, /not yet approved/i);
  assert.doesNotMatch(model, /production credentials/i);
});
