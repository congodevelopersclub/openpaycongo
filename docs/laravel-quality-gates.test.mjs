import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const readWorkspaceFile = (path) => readFile(new URL(path, import.meta.url), 'utf8');

test('canonical Laravel quality gates are documented and run in Docker', async () => {
  const [composer, dockerfile, phpstan, readme, workflow, runner] = await Promise.all([
    readWorkspaceFile('../server/composer.json'),
    readWorkspaceFile('../server/Dockerfile'),
    readWorkspaceFile('../server/phpstan.neon'),
    readWorkspaceFile('../README.md'),
    readWorkspaceFile('../.github/workflows/ci.yml'),
    readWorkspaceFile('../scripts/ci/fast-feedback.sh'),
  ]);
  const manifest = JSON.parse(composer);

  assert.ok(manifest['require-dev']['laravel/boost']);
  assert.ok(manifest['require-dev']['larastan/larastan']);
  assert.equal(manifest.scripts.lint, 'pint --test');
  assert.equal(manifest.scripts.analyse, 'phpstan analyse --configuration=phpstan.neon');
  assert.equal(manifest.config.platform.php, '8.3.0');
  assert.match(dockerfile, /php:8\.3-cli-alpine@sha256:afdf8b1fee58486ccc0dab5f30f634b86873d56dac985f71ba217945647c05ad AS php83-platform-check/);
  assert.match(dockerfile, /composer:2\.9@sha256:b09bccd91a78fe8a9ab4b33d707b862e8fe54fec17782e32683ad2a69c46867d/);
  assert.match(dockerfile, /libpq=18\.6-r0/);
  assert.match(dockerfile, /composer install --dry-run/);
  assert.match(dockerfile, /composer run lint/);
  assert.match(dockerfile, /composer run analyse/);
  assert.match(dockerfile, /composer test/);
  assert.match(phpstan, /vendor\/larastan\/larastan\/extension\.neon/);
  assert.match(phpstan, /level: 5/);
  assert.match(readme, /local laravel/);
  assert.match(workflow, /bash scripts\/ci\/fast-feedback\.sh pr laravel/);
  assert.match(runner, /docker build --target test -f server\/Dockerfile \./);
  assert.match(runner, /docker build --target production-contract -f server\/Dockerfile \./);
});
