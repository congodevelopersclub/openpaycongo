import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('security gate uses local scanners and keeps full controls off ordinary pull requests', async () => {
  const workflow = await readFile(new URL('../.github/workflows/security.yml', import.meta.url), 'utf8');
  const fast = await readFile(new URL('../scripts/security/security-fast.sh', import.meta.url), 'utf8');
  const history = await readFile(new URL('../scripts/security/security-history.sh', import.meta.url), 'utf8');
  const full = await readFile(new URL('../scripts/security/security-full.sh', import.meta.url), 'utf8');
  const proofs = await readFile(new URL('../scripts/security/verify-enforced-controls.sh', import.meta.url), 'utf8');
  const fullProofs = await readFile(new URL('../scripts/security/verify-full-controls.sh', import.meta.url), 'utf8');
  const guide = await readFile(new URL('../docs/continuous-security-gate.md', import.meta.url), 'utf8');
  const gitleaksConfig = await readFile(new URL('../.gitleaks.toml', import.meta.url), 'utf8');
  const authorizationBoundary = await readFile(new URL('../server/tests/Feature/AuthorizationBoundaryTest.php', import.meta.url), 'utf8');
  const dockerignore = await readFile(new URL('../.dockerignore', import.meta.url), 'utf8');
  const serverDockerfile = await readFile(new URL('../server/Dockerfile', import.meta.url), 'utf8');

  for (const required of ['pull_request:', 'schedule:', "tags: ['v*']", 'security-fast', 'security-full', 'workflow_dispatch:', 'timeout-minutes:', 'fetch-depth: 0']) {
    assert.match(workflow, new RegExp(required.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
  assert.match(workflow, /github\.event_name != 'pull_request'/);
  assert.doesNotMatch(workflow, /actions\/cache|trivy-cache/);
  assert.match(fast, /gitleaks@sha256:/);
  assert.match(fast, /\.gitleaks\.toml/);
  assert.match(gitleaksConfig, /Exact deterministic public vector values/);
  assert.match(gitleaksConfig, /regexTarget = "secret"/);
  assert.match(gitleaksConfig, /\^96cca119fadda9490c972d89459c944df15ba4c1afdad5806d9148ee99e73888\$/);
  assert.doesNotMatch(gitleaksConfig, /paths\s*=/);
  assert.doesNotMatch(gitleaksConfig, /artifacts\/security/);
  assert.match(fast, /trivy@sha256:/);
  assert.match(fast, /server/);
  assert.match(fast, /android-client/);
  assert.doesNotMatch(fast, /laravel-reference/);
  assert.match(history, /git --config=.*--log-opts=--all --redact --exit-code=1/);
  assert.match(fast, /dir --config=.*--redact --exit-code=1/);
  assert.match(full, /cyclonedx-json/);
  assert.match(full, /bash "\$\{root\}\/scripts\/security\/security-fast\.sh"/);
  assert.match(full, /image --scanners vuln --severity HIGH,CRITICAL --exit-code 1/);
  assert.match(full, /\/var\/run\/docker\.sock:\/var\/run\/docker\.sock:ro/);
  assert.match(fullProofs, /\/var\/run\/docker\.sock:\/var\/run\/docker\.sock:ro/);
  for (const productionArtifact of ['congo-openpay-fpm:security', 'congo-openpay-nginx:security', 'openpaycongo-server-test:security', 'openpaycongo-fpm-production.cdx.json', 'openpaycongo-nginx-production.cdx.json']) {
    assert.match(full, new RegExp(productionArtifact.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
  assert.match(workflow, /actions\/upload-artifact@[\s\S]*?\n\s+if: always\(\)[\s\S]*?if-no-files-found: error/);
  for (const control of ['vulnerable-composer', 'vulnerable-flutter', 'security-composer-audit-proof', 'security-php-static-proof', 'security-authorization-proof', 'analyze-proof']) {
    assert.match(proofs, new RegExp(control));
  }
  assert.match(fullProofs, /alpine@sha256:/);
  assert.match(fullProofs, /openpaycongo-server\.cdx\.json/);
  assert.match(fullProofs, /openpaycongo-android-client\.cdx\.json/);
  assert.match(fullProofs, /openpaycongo-fpm-production\.cdx\.json/);
  assert.match(fullProofs, /openpaycongo-nginx-production\.cdx\.json/);
  assert.match(fullProofs, /vulnerable-composer/);
  assert.match(authorizationBoundary, /storage\/not-signed\?upload=true/);
  assert.match(authorizationBoundary, /assertForbidden\(\)/);
  assert.match(authorizationBoundary, /auth\.optional/);
  assert.match(authorizationBoundary, /authorize-anything/);
  assert.doesNotMatch(authorizationBoundary, /str_starts_with\(\$middleware, 'auth'\)/);
  assert.doesNotMatch(authorizationBoundary, /WithoutErrorHandler/);
  assert.match(await readFile(new URL('../scripts/security/verify-secret-scanner.sh', import.meta.url), 'utf8'), /seeded secret appended to a deterministic vector/);
  assert.doesNotMatch(authorizationBoundary, /file_put_contents|unlink|\.env/);
  assert.match(dockerignore, /^server\/\.env$/m);
  assert.doesNotMatch(serverDockerfile, /COPY\s+server\/\.env/);
  assert.match(serverDockerfile, /FROM quality AS test[\s\S]*?: > \.env[\s\S]*?composer test/);
  assert.match(serverDockerfile, /FROM dependencies AS security-authorization-proof[\s\S]*?: > \.env/);
  assert.match(serverDockerfile, /security-gate-lookalike-fixture[\s\S]*?auth\.optional/);
  assert.match(serverDockerfile, /FROM dependencies AS security-php-static-proof[\s\S]*?SecurityGateBrokenFixture[\s\S]*?composer run analyse/);
  assert.doesNotMatch(serverDockerfile, /security-php-static-proof[\s\S]*?composer run lint/);
  assert.match(serverDockerfile, /FROM php83-platform-check AS dependencies/);
  assert.match(serverDockerfile, /docker-php-ext-install pdo_pgsql pdo_mysql/);
  assert.match(serverDockerfile, /FROM production AS production-contract/);
  const nginxDockerfile = await readFile(new URL('../server/docker/nginx.Dockerfile', import.meta.url), 'utf8');
  assert.match(nginxDockerfile, /FROM production AS production-contract/);
  assert.doesNotMatch(serverDockerfile, /composer-security-base|apk upgrade --no-cache/);
  assert.match(guide, /PostgreSQL and MySQL PDO extensions/);
  assert.match(guide, /congo-openpay-fpm:security/);
  assert.match(guide, /congo-openpay-nginx:security/);
  assert.match(guide, /fail-closed/);
  assert.match(guide, /release blocker/);
  assert.match(guide, /candidate-tag pushes/);
  assert.match(guide, /Repository governance issue #10/);
  assert.match(guide, /Docker build context excludes `server\/\.env`/);
  assert.doesNotMatch(fast, /curl\s+.*https?:\/\//i);
});
