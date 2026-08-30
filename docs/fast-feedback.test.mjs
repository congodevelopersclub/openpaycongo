import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { chmod, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const runnerPath = resolve(repositoryRoot, 'scripts/ci/fast-feedback.sh');

const withHarness = async (run) => {
  const directory = await mkdtemp(resolve(tmpdir(), 'openpay-fast-feedback-'));
  const log = resolve(directory, 'calls.log');
  for (const name of ['docker', 'bash', 'grep']) {
    const path = resolve(directory, name);
    const fake = name === 'docker'
      ? '#!/bin/sh\nstate() { [ -n "$1" ] && printf set || printf missing; }\nif [ "$1" = compose ] && [ "$2" = config ]; then\n  printf "docker compose config APP_KEY=%s DB_PASSWORD=%s LOOKUP_TOKEN=%s\\n" "$(state "$OPENPAY_APP_KEY")" "$(state "$OPENPAY_DB_PASSWORD")" "$(state "$DEPOSIT_LOOKUP_TOKEN_KEY")" >> "$FAST_FEEDBACK_LOG"\nelse\n  printf "docker %s\\n" "$*" >> "$FAST_FEEDBACK_LOG"\nfi\nif [ -n "$FAST_FEEDBACK_FAIL_MATCH" ] && printf "%s" "$*" | /bin/grep -Fq -- "$FAST_FEEDBACK_FAIL_MATCH"; then exit 97; fi\nif [ "$1" = compose ] && [ "$2" = config ]; then\n  case "$FAST_FEEDBACK_ACCEPT_MISSING" in APP_KEY) [ -z "$OPENPAY_APP_KEY" ] && exit 0 ;; DB_PASSWORD) [ -z "$OPENPAY_DB_PASSWORD" ] && exit 0 ;; LOOKUP_TOKEN) [ -z "$DEPOSIT_LOOKUP_TOKEN_KEY" ] && exit 0 ;; esac\n  [ -n "$OPENPAY_APP_KEY" ] && [ -n "$OPENPAY_DB_PASSWORD" ] && [ -n "$DEPOSIT_LOOKUP_TOKEN_KEY" ] || exit 1\nfi\ncase " $* " in *" psql "*) printf "%s\\n" "deposits_reverses_deposit_id_foreign:FOREIGN KEY" "deposits_reverses_deposit_id_unique:UNIQUE" ;; esac\n'
      : name === 'grep'
        ? '#!/bin/sh\nprintf "grep %s\\n" "$*" >> "$FAST_FEEDBACK_LOG"\nif [ -n "$FAST_FEEDBACK_FAIL_MATCH" ] && printf "%s" "$*" | /bin/grep -Fq -- "$FAST_FEEDBACK_FAIL_MATCH"; then exit 97; fi\nexec /bin/grep "$@"\n'
        : '#!/bin/sh\nprintf "bash %s\\n" "$*" >> "$FAST_FEEDBACK_LOG"\nif [ -n "$FAST_FEEDBACK_FAIL_MATCH" ] && printf "%s" "$*" | /bin/grep -Fq "$FAST_FEEDBACK_FAIL_MATCH"; then exit 97; fi\n';
    await writeFile(path, fake);
    await chmod(path, 0o755);
  }
  try {
    const invokeWithEnvironment = (environment, ...arguments_) => spawnSync('/bin/bash', [runnerPath, ...arguments_], {
      cwd: repositoryRoot,
      encoding: 'utf8',
      env: { ...process.env, FAST_FEEDBACK_ACCEPT_MISSING: '', FAST_FEEDBACK_FAIL_MATCH: '', ...environment, FAST_FEEDBACK_LOG: log, PATH: `${directory}:${process.env.PATH}` },
    });
    const invokeWithFailure = (failureMatch, ...arguments_) => invokeWithEnvironment({ FAST_FEEDBACK_FAIL_MATCH: failureMatch }, ...arguments_);
    const invoke = (...arguments_) => invokeWithFailure('', ...arguments_);
    await run(
      invoke,
      async () => { try { return await readFile(log, 'utf8'); } catch { return ''; } },
      () => writeFile(log, ''),
      invokeWithFailure,
      invokeWithEnvironment,
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
};

const postgresClientImages = (lines) => lines.map((line) => {
  assert.match(line.trimStart(), /^docker run /, `noncanonical Docker invocation: ${line.trim()}`);
  assert.equal((line.match(/\bdocker\b/g) ?? []).length, 1, `multiple Docker invocations: ${line.trim()}`);
  assert.doesNotMatch(line, /[;&|]/, `chained Docker invocation: ${line.trim()}`);
  const arguments_ = line.trim().slice('docker run '.length).split(/\s+/);
  let index = 0;
  while (arguments_[index]?.startsWith('--')) {
    const option = arguments_[index++];
    if (option === '--rm') continue;
    if (option === '--network' || option === '--env') { index++; continue; }
    assert.fail(`unexpected docker run option: ${option}`);
  }
  return arguments_[index];
});

test('fast-feedback runner exposes Docker-only focused, local, PR, main, and scheduled tiers', async () => {
  const runner = await readFile(resolve(repositoryRoot, 'scripts/ci/fast-feedback.sh'), 'utf8');

  for (const tier of ['focused', 'local', 'pr', 'main', 'deploy', 'scheduled']) {
    assert.match(runner, new RegExp(`\\b${tier}\\)`), `missing ${tier} tier`);
  }

  for (const component of ['contracts', 'laravel', 'flutter', 'postgres-migration', 'deposit-concurrency']) {
    assert.match(runner, new RegExp(`\\b${component}\\)`), `missing ${component} component`);
  }

  assert.match(runner, /docker build/);
  assert.doesNotMatch(runner, /(?:^|\n)\s*(?:php|composer|flutter|npm)\s+(?:test|run|analyze|analyse)/m);
  for (const command of [
    'docker build --target focused --build-arg TEST_PATH="$1" -f docs/Dockerfile .',
    'docker build --target focused --build-arg TEST_FILTER="$1" -f server/Dockerfile .',
    'docker build --target focused --build-arg TEST_PATH="$1" -f android-client/Dockerfile.ci android-client',
    'docker build --target test -f server/Dockerfile .',
    'docker build --target production-contract -f server/docker/nginx.Dockerfile .',
    'docker build --target artifact --output type=local,dest=android-client/build/ci -f android-client/Dockerfile.ci android-client',
  ]) assert.ok(runner.includes(command), `missing canonical command: ${command}`);

  const postgresImage = 'postgres:16-alpine@sha256:cf78e76683b9ca8c5733cbbdce6c9262b45b6767934dd0a95e671f9a0fc20685';
  const postgresLines = runner.split('\n').filter((line) => line.trimStart().startsWith('docker run ') && line.includes(postgresImage));
  assert.deepEqual(postgresClientImages(postgresLines), [postgresImage, postgresImage]);
  assert.throws(() => postgresClientImages([`env PGPASSWORD=openpay docker run --rm ${postgresImage}`]), /noncanonical Docker invocation/);
  assert.throws(() => postgresClientImages([`docker run --rm ${postgresImage}; docker run --rm ${postgresImage}`]), /multiple Docker invocations|chained Docker invocation/);
  assert.match(runner, /deposits_reverses_deposit_id_foreign:FOREIGN KEY/);
  assert.match(runner, /deposits_reverses_deposit_id_unique:UNIQUE/);
  assert.match(runner, /MSYS_NO_PATHCONV=1 docker run --rm -v \/var\/run\/docker\.sock/);
  assert.match(runner, /aquasec\/trivy@sha256:bcc376de8d77cfe086a917230e818dc9f8528e3c852f7b1aff648949b6258d1c image --scanners vuln --severity HIGH,CRITICAL --exit-code 1 --skip-version-check "\$image"/);
  assert.match(runner, /for image in congo-openpay-fpm:ci congo-openpay-nginx:ci/);
  assert.match(runner, /T3 immutable artifact publication and provenance are not implemented/);
  assert.match(runner, /T4 exact-artifact promotion and production-like verification are not implemented/);
});

test('runner dispatches actual tier commands and fails closed for unavailable tiers', async () => {
  await withHarness(async (invoke, calls, clearCalls, invokeWithFailure, invokeWithEnvironment) => {
    const cases = [
      [['focused', 'contracts', 'docs/public-contract.test.mjs'], ['docker build --target focused --build-arg TEST_PATH=docs/public-contract.test.mjs -f docs/Dockerfile .']],
      [['focused', 'laravel', 'ProductionRuntimeContractTest'], ['docker build --target focused --build-arg TEST_FILTER=ProductionRuntimeContractTest -f server/Dockerfile .']],
      [['focused', 'flutter', 'test/features/payment_lifecycle_bloc_test.dart'], ['docker build --target focused --build-arg TEST_PATH=test/features/payment_lifecycle_bloc_test.dart -f android-client/Dockerfile.ci android-client']],
      [['local', 'contracts'], ['docker build --target test -f docs/Dockerfile .']],
      [['local', 'laravel'], ['docker build --target test -f server/Dockerfile .']],
      [['local', 'flutter'], ['docker build --target analyze -f android-client/Dockerfile.ci android-client', 'docker build --target test -f android-client/Dockerfile.ci android-client']],
      [['pr', 'contracts'], ['docker build --target test -f docs/Dockerfile .']],
      [['pr', 'laravel'], ['docker compose config APP_KEY=set DB_PASSWORD=set LOOKUP_TOKEN=set', 'docker build --target test -f server/Dockerfile .', 'docker build --target production-contract -f server/Dockerfile .', 'docker build --target production-contract -f server/docker/nginx.Dockerfile .', 'docker build --target production --tag congo-openpay-fpm:ci -f server/Dockerfile .', 'docker build --target production --tag congo-openpay-nginx:ci -f server/docker/nginx.Dockerfile .', 'image --scanners vuln --severity HIGH,CRITICAL --exit-code 1 --skip-version-check congo-openpay-fpm:ci', 'image --scanners vuln --severity HIGH,CRITICAL --exit-code 1 --skip-version-check congo-openpay-nginx:ci']],
      [['pr', 'flutter'], ['docker build --target analyze -f android-client/Dockerfile.ci android-client', 'docker build --target test -f android-client/Dockerfile.ci android-client', 'docker build --target artifact --output type=local,dest=android-client/build/ci -f android-client/Dockerfile.ci android-client']],
      [['pr', 'postgres-migration'], ['docker build --target quality --tag openpaycongo-server-postgres -f server/Dockerfile .', 'docker run --rm --network host --env APP_ENV=testing --env APP_KEY=base64:MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE= --env DB_CONNECTION=pgsql --env DB_HOST=127.0.0.1 --env DB_PORT=5432 --env DB_DATABASE=openpaycongo --env DB_USERNAME=openpay --env DB_PASSWORD=openpay openpaycongo-server-postgres php artisan migrate:fresh --force', 'psql --host=127.0.0.1 --port=5432', 'grep -Fx deposits_reverses_deposit_id_foreign:FOREIGN KEY', 'grep -Fx deposits_reverses_deposit_id_unique:UNIQUE']],
      [['pr', 'deposit-concurrency', 'pgsql', '5432'], ['docker build --target quality --tag openpaycongo-server-concurrency -f server/Dockerfile .', 'bash server/tests/Support/run_provider_deposit_concurrency_matrix.sh openpaycongo-server-concurrency pgsql 5432', 'bash server/tests/Support/run_payment_request_concurrency_matrix.sh openpaycongo-server-concurrency pgsql 5432']],
      [['pr', 'security'], ['bash scripts/security/security-fast.sh', 'bash scripts/security/security-history.sh', 'bash scripts/security/verify-secret-scanner.sh', 'bash scripts/security/verify-enforced-controls.sh']],
      [['scheduled', 'security'], ['bash scripts/security/security-full.sh', 'bash scripts/security/verify-full-controls.sh']],
    ];
    for (const [arguments_, expected] of cases) {
      await clearCalls();
      const result = invoke(...arguments_);
      assert.equal(result.status, 0, `${arguments_.join(' ')}: ${result.stderr}`);
      const log = await calls();
      for (const call of expected) assert.ok(log.includes(call), `missing call: ${call}`);
      if (arguments_[1] === 'postgres-migration') assert.equal((log.match(/psql --host=127\.0\.0\.1 --port=5432/g) ?? []).length, 2, 'expected two PostgreSQL constraint queries');
    }
    for (const tier of ['main', 'deploy']) {
      const result = invoke(tier, 'laravel');
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, new RegExp(`T[34] .*not implemented`));
    }
    await clearCalls();
    const laravel = invoke('pr', 'laravel');
    assert.equal(laravel.status, 0, laravel.stderr);
    assert.deepEqual((await calls()).split('\n').filter((line) => line.startsWith('docker compose config')), [
      'docker compose config APP_KEY=set DB_PASSWORD=set LOOKUP_TOKEN=set',
      'docker compose config APP_KEY=missing DB_PASSWORD=set LOOKUP_TOKEN=set',
      'docker compose config APP_KEY=set DB_PASSWORD=missing LOOKUP_TOKEN=set',
      'docker compose config APP_KEY=set DB_PASSWORD=set LOOKUP_TOKEN=missing',
    ]);
    for (const acceptedMissing of ['APP_KEY', 'DB_PASSWORD', 'LOOKUP_TOKEN']) {
      const result = invokeWithEnvironment({ FAST_FEEDBACK_ACCEPT_MISSING: acceptedMissing }, 'pr', 'laravel');
      assert.notEqual(result.status, 0, `Laravel accepted missing ${acceptedMissing}`);
    }
    for (const [arguments_, expected] of cases) {
      if (!['pr', 'scheduled'].includes(arguments_[0])) continue;
      for (const call of expected) {
        const failedCall = call.startsWith('docker compose config') ? 'compose config' : call.replace(/^(?:docker|bash|grep) /, '');
        const result = invokeWithFailure(failedCall, ...arguments_);
        assert.notEqual(result.status, 0, `${arguments_.join(' ')} masked ${failedCall}`);
      }
    }
  });
});

test('focused selectors reject option injection and missing tests before Docker', async () => {
  await withHarness(async (invoke, calls) => {
    for (const arguments_ of [
      ['focused', 'contracts', '--help'],
      ['focused', 'contracts', 'docs/missing.test.mjs'],
      ['focused', 'flutter', '--help'],
      ['focused', 'flutter', 'test/missing_test.dart'],
      ['focused', 'laravel', '--help'],
    ]) assert.notEqual(invoke(...arguments_).status, 0, `${arguments_.join(' ')} must fail`);
    assert.equal(await calls(), '');
  });
});

test('runner does not hide command failure with a no-op control operator', async () => {
  const runner = await readFile(runnerPath, 'utf8');
  const commands = [];
  let command = '';
  for (const line of runner.split('\n')) {
    if (command) {
      command += `\n${line}`;
      if (!line.endsWith('\\')) { commands.push(command); command = ''; }
    } else if (/^\s*(?:(?:MSYS_NO_PATHCONV=1 )?docker|bash)\b/.test(line)) {
      command = line;
      if (!line.endsWith('\\')) { commands.push(command); command = ''; }
    }
  }
  const assertNoShellRecovery = (command) => {
    const unquoted = command.replace(/'(?:[^']*)'|"(?:[^"\\]|\\.)*"/g, '');
    assert.doesNotMatch(unquoted, /\|\|/, `shell recovery operator: ${command}`);
    assert.doesNotMatch(unquoted, /\|\s*true\b/, `weakened pipeline: ${command}`);
    assert.doesNotMatch(unquoted, /;/, `chained shell command: ${command}`);
  };
  for (const command of commands) assertNoShellRecovery(command);
  assert.throws(() => assertNoShellRecovery('docker build --target test . || echo ignored'), /shell recovery operator/);
  assert.throws(() => assertNoShellRecovery('bash scripts/security/security-fast.sh; echo ignored'), /chained shell command/);
  assert.throws(() => assertNoShellRecovery('docker run postgres | true'), /weakened pipeline/);
});
