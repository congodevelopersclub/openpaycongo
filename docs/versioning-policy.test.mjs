import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('./', import.meta.url);

test('versioning policy separates observable identity from pending compatibility authority', async () => {
  const policy = await readFile(new URL('versioning-policy.md', root), 'utf8');

  for (const heading of ['## Observable version identity', '## Change classification', '## Compatibility and fixture gates', '## Pending maintainer authority']) {
    assert.match(policy, new RegExp(heading.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
  assert.match(policy, /contract_version/);
  assert.match(policy, /migration_revision/);
  assert.match(policy, /breaking/i);
  assert.match(policy, /additive/i);
  assert.match(policy, /intentional-breaking-change/i);
  assert.match(policy, /not yet approved/i);
  assert.doesNotMatch(policy, /supported for \d+/i);
});
