#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
artifacts="${root}/artifacts/security"
trivy_cache="openpaycongo-security-trivy-cache"
trivy_image="aquasec/trivy@sha256:bcc376de8d77cfe086a917230e818dc9f8528e3c852f7b1aff648949b6258d1c"
vulnerable_image="alpine@sha256:c75ac27b49326926b803b9ed43bf088bc220d22556de1bc5f72d742c91398f69"

server_sbom="${artifacts}/openpaycongo-server.cdx.json"
mobile_sbom="${artifacts}/openpaycongo-android-client.cdx.json"

test -s "${server_sbom}"
test -s "${mobile_sbom}"
grep --quiet '"bomFormat": "CycloneDX"' "${server_sbom}"
grep --quiet '"bomFormat": "CycloneDX"' "${mobile_sbom}"
grep --quiet 'laravel/framework' "${server_sbom}"
grep --quiet 'local_auth' "${mobile_sbom}"
if grep --quiet 'scripts/security/fixtures\|vulnerable-composer\|vulnerable-flutter' "${server_sbom}" "${mobile_sbom}"; then
  echo 'SBOM included a controlled security fixture outside an application dependency tree' >&2
  exit 1
fi

result="$(mktemp)"
trap 'rm -f "${result}"' EXIT

if MSYS_NO_PATHCONV=1 docker run --rm --volume /var/run/docker.sock:/var/run/docker.sock --volume "${trivy_cache}:/root/.cache/trivy" "${trivy_image}" \
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

echo 'SBOM generation and container scanner rejected their controlled checks'
