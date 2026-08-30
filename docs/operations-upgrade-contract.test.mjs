import assert from 'node:assert/strict';
import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const script = resolve('scripts/upgrade-quiescent.sh');

async function run(migrateStatus) {
  const directory = await mkdtemp(join(tmpdir(), 'openpay-upgrade-'));
  const log = join(directory, 'commands');
  const docker = join(directory, 'docker');
  const executable = join(directory, 'upgrade-quiescent.sh');
  await writeFile(docker, `#!/bin/sh\necho "$*" >> "$OPENPAY_TEST_LOG"\n[ "$2" = run ] && exit ${migrateStatus}\n`);
  await writeFile(executable, (await readFile(script, 'utf8')).replaceAll('\r\n', '\n'));
  await chmod(docker, 0o755);
  const result = spawnSync('sh', [executable], { env: { ...process.env, OPENPAY_DOCKER_BIN: docker, OPENPAY_TEST_LOG: log } });
  const commands = (await readFile(log, 'utf8')).trim().split('\n');
  await rm(directory, { recursive: true });
  return { result, commands };
}

test('quiescent upgrade stops writers, migrates, then restarts them', async () => {
  const { result, commands } = await run(0);
  assert.equal(result.status, 0);
  assert.deepEqual(commands, ['compose stop nginx php queue scheduler', 'compose run --rm migrate', 'compose up -d --force-recreate php nginx queue scheduler']);
});

test('quiescent upgrade leaves writers stopped after migration failure', async () => {
  const { result, commands } = await run(17);
  assert.equal(result.status, 1);
  assert.deepEqual(commands, ['compose stop nginx php queue scheduler', 'compose run --rm migrate']);
});
