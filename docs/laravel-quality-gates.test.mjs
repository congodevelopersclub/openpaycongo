import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const readWorkspaceFile = (path) => readFile(new URL(path, import.meta.url), 'utf8');

test('canonical Laravel quality gates are documented and run in Docker', async () => {
  const [composer, dockerfile, phpstan, readme, workflow] = await Promise.all([
    readWorkspaceFile('../server/composer.json'),
    readWorkspaceFile('../server/Dockerfile'),
    readWorkspaceFile('../server/phpstan.neon'),
    readWorkspaceFile('../README.md'),
    readWorkspaceFile('../.github/workflows/ci.yml'),
  ]);
  const manifest = JSON.parse(composer);

  assert.ok(manifest['require-dev']['laravel/boost']);
  assert.ok(manifest['require-dev']['larastan/larastan']);
  assert.equal(manifest.scripts.lint, 'pint --test');
  assert.equal(manifest.scripts.analyse, 'phpstan analyse --configuration=phpstan.neon');
  assert.equal(manifest.config.platform.php, '8.3.0');
  assert.match(dockerfile, /php:8\.3-cli-alpine AS php83-platform-check/);
  assert.match(dockerfile, /composer install --dry-run/);
  assert.match(dockerfile, /composer run lint/);
  assert.match(dockerfile, /composer run analyse/);
  assert.match(dockerfile, /composer test/);
  assert.match(phpstan, /vendor\/larastan\/larastan\/extension\.neon/);
  assert.match(phpstan, /level: 5/);
  assert.match(readme, /composer\s+run quality/);
  assert.match(workflow, /Run canonical Laravel quality gates and tests in Docker/);
});
