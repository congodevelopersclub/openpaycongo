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

  for (const required of ['pull_request:', 'schedule:', 'release:', 'security-fast', 'security-full', 'workflow_dispatch:', 'timeout-minutes:', 'fetch-depth: 0']) {
    assert.match(workflow, new RegExp(required.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
  assert.match(workflow, /github\.event_name != 'pull_request'/);
  assert.match(fast, /gitleaks@sha256:/);
  assert.match(fast, /\.gitleaks\.toml/);
  assert.match(gitleaksConfig, /Exact deterministic public vector values/);
  assert.match(gitleaksConfig, /regexTarget = "secret"/);
  assert.doesNotMatch(gitleaksConfig, /paths\s*=/);
  assert.doesNotMatch(gitleaksConfig, /artifacts\/security/);
  assert.match(fast, /trivy@sha256:/);
  assert.match(fast, /server/);
  assert.match(fast, /android-client/);
  assert.doesNotMatch(fast, /laravel-reference/);
  assert.match(history, /git --config=.*--log-opts=--all --redact --exit-code=1/);
  assert.match(fast, /dir --config=.*--redact --exit-code=1/);
  assert.match(full, /cyclonedx-json/);
  assert.match(full, /image --severity HIGH,CRITICAL --exit-code 1/);
  for (const control of ['vulnerable-composer', 'vulnerable-flutter', 'security-composer-audit-proof', 'security-php-static-proof', 'security-authorization-proof', 'analyze-proof']) {
    assert.match(proofs, new RegExp(control));
  }
  assert.match(fullProofs, /alpine@sha256:/);
  assert.match(fullProofs, /openpaycongo-server\.cdx\.json/);
  assert.match(fullProofs, /openpaycongo-android-client\.cdx\.json/);
  assert.match(fullProofs, /vulnerable-composer/);
  assert.match(authorizationBoundary, /storage\/not-signed\?upload=true/);
  assert.match(authorizationBoundary, /assertForbidden\(\)/);
  assert.match(authorizationBoundary, /#\[WithoutErrorHandler\]/);
  assert.match(await readFile(new URL('../scripts/security/verify-secret-scanner.sh', import.meta.url), 'utf8'), /seeded secret appended to a deterministic vector/);
  assert.doesNotMatch(authorizationBoundary, /file_put_contents|unlink|\.env/);
  assert.match(guide, /fail-closed/);
  assert.match(guide, /release blocker/);
  assert.doesNotMatch(fast, /curl\s+.*https?:\/\//i);
});
