#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
artifacts="${root}/artifacts/security"
trivy_cache="openpaycongo-security-trivy-cache"
trivy_image="aquasec/trivy@sha256:bcc376de8d77cfe086a917230e818dc9f8528e3c852f7b1aff648949b6258d1c"
vulnerable_image="alpine@sha256:c75ac27b49326926b803b9ed43bf088bc220d22556de1bc5f72d742c91398f69"

server_sbom="${artifacts}/openpaycongo-server.cdx.json"
mobile_sbom="${artifacts}/openpaycongo-android-client.cdx.json"
fpm_sbom="${artifacts}/openpaycongo-fpm-production.cdx.json"
nginx_sbom="${artifacts}/openpaycongo-nginx-production.cdx.json"

test -s "${server_sbom}"
test -s "${mobile_sbom}"
test -s "${fpm_sbom}"
test -s "${nginx_sbom}"
for sbom in "${server_sbom}" "${mobile_sbom}" "${fpm_sbom}" "${nginx_sbom}"; do
  grep --extended-regexp --quiet '"bomFormat"[[:space:]]*:[[:space:]]*"CycloneDX"' "${sbom}"
done
grep --quiet 'laravel/framework' "${server_sbom}"
grep --quiet 'local_auth' "${mobile_sbom}"
grep --quiet 'laravel/framework' "${fpm_sbom}"
grep --quiet 'nginx' "${nginx_sbom}"
if grep --quiet 'scripts/security/fixtures\|vulnerable-composer\|vulnerable-flutter' "${server_sbom}" "${mobile_sbom}" "${fpm_sbom}" "${nginx_sbom}"; then
  echo 'SBOM included a controlled security fixture outside an application dependency tree' >&2
  exit 1
fi

result="$(mktemp)"
failing_fast_gate="$(mktemp)"
failure_artifacts="$(mktemp -d "${artifacts}/seeded-fast-gate.XXXXXX")"
trap 'rm -f "${result}" "${failing_fast_gate}"; rm -rf "${failure_artifacts}"' EXIT

if MSYS_NO_PATHCONV=1 docker run --rm --volume /var/run/docker.sock:/var/run/docker.sock:ro --volume "${trivy_cache}:/root/.cache/trivy" "${trivy_image}" \
  image --scanners vuln --quiet --severity HIGH,CRITICAL --exit-code 1 "${vulnerable_image}" >"${result}" 2>&1; then
  echo 'Container scanner accepted the pinned vulnerable image fixture' >&2
  cat "${result}" >&2
  exit 1
fi

if ! grep --quiet --fixed-strings 'CVE-2022-37434' "${result}"; then
  echo 'Container scanner failed without the expected vulnerable-image finding' >&2
  cat "${result}" >&2
  exit 1
fi

cat "${result}"

printf '%s\n' '#!/usr/bin/env bash' 'echo seeded-fast-gate-failure >&2' 'exit 42' >"${failing_fast_gate}"
set +e
OPENPAY_SECURITY_FAST_GATE="${failing_fast_gate}" OPENPAY_SECURITY_ARTIFACTS_DIR="${failure_artifacts}" \
  bash "${root}/scripts/security/security-full.sh" >"${result}" 2>&1
full_status=$?
set -e

if [ "${full_status}" -ne 42 ]; then
  echo "Full security gate returned ${full_status}, not the seeded fast-gate status 42" >&2
  cat "${result}" >&2
  exit 1
fi

grep --quiet --fixed-strings 'seeded-fast-gate-failure' "${result}"
grep --quiet --fixed-strings 'Fast security gate failed; retaining generated SBOMs before propagating its exit status' "${result}"
for sbom in openpaycongo-server.cdx.json openpaycongo-android-client.cdx.json openpaycongo-fpm-production.cdx.json openpaycongo-nginx-production.cdx.json; do
  test -s "${failure_artifacts}/${sbom}"
done

echo 'Source and production SBOM generation plus container scanning rejected their controlled checks and retained SBOMs after a seeded fast-gate failure'
