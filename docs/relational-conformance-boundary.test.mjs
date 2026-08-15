import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('relational conformance boundary preserves existing logical invariants without claiming adapters', async () => {
  const boundary = await readFile(new URL('./relational-conformance-boundary.md', import.meta.url), 'utf8');

  for (const section of [
    '## Verified public invariants',
    '## Required schema mapping',
    '## Conformance fixture gate',
    '## Adapter and migration boundary',
  ]) {
    assert.match(boundary, new RegExp(section.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }

  assert.match(boundary, /UNIQUE\(tenant_id,idempotency_key\)/);
  assert.match(boundary, /canonical JSON/i);
  assert.match(boundary, /not yet defined/i);
  assert.match(boundary, /does not claim/i);
  assert.match(boundary, /unknown revision/i);
  assert.match(boundary, /does not claim a\s+production-ready adapter/i);
});
