#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
trivy_image="aquasec/trivy@sha256:bcc376de8d77cfe086a917230e818dc9f8528e3c852f7b1aff648949b6258d1c"
trivy_cache="${root}/artifacts/security/trivy-cache"

mkdir -p "${trivy_cache}"

expect_failure() {
  local name="$1"
  shift
  if "$@"; then
    echo "${name} accepted its seeded failure" >&2
    exit 1
  fi
  echo "${name} rejected its seeded failure"
}

expect_failure 'Composer lockfile audit' env MSYS_NO_PATHCONV=1 docker run --rm --volume "${root}:/repo:ro" --volume "${trivy_cache}:/root/.cache/trivy" --workdir /repo "${trivy_image}" \
  fs --scanners vuln --severity HIGH,CRITICAL --exit-code 1 scripts/security/fixtures/vulnerable-composer
expect_failure 'Flutter lockfile audit' env MSYS_NO_PATHCONV=1 docker run --rm --volume "${root}:/repo:ro" --volume "${trivy_cache}:/root/.cache/trivy" --workdir /repo "${trivy_image}" \
  fs --scanners vuln --severity HIGH,CRITICAL --exit-code 1 scripts/security/fixtures/vulnerable-flutter
docker build --target security-composer-audit-proof -f "${root}/server/Dockerfile" "${root}"
docker build --target security-php-static-proof -f "${root}/server/Dockerfile" "${root}"
docker build --target security-authorization-proof -f "${root}/server/Dockerfile" "${root}"
docker build --target analyze-proof -f "${root}/android-client/Dockerfile.ci" "${root}/android-client"
