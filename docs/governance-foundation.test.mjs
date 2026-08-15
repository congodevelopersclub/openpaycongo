import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import test from 'node:test';

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const read = (path) => readFile(resolve(repositoryRoot, path), 'utf8');

test('public contributor and reporting guidance requires evidence without soliciting secrets', async () => {
  const [contributing, security, pullRequest, issueTemplate] = await Promise.all([
    read('CONTRIBUTING.md'),
    read('SECURITY.md'),
    read('.github/PULL_REQUEST_TEMPLATE.md'),
    read('.github/ISSUE_TEMPLATE/bug_report.md'),
  ]);

  assert.match(contributing, /Docker/i);
  assert.match(contributing, /rollback/i);
  assert.match(contributing, /maintainer decision/i);
  assert.match(security, /Do not publish/i);
  assert.match(security, /not yet published/i);
  assert.match(pullRequest, /evidence/i);
  assert.match(pullRequest, /rollback/i);
  assert.match(issueTemplate, /reproduction/i);
  assert.match(issueTemplate, /Do not include/i);
});
