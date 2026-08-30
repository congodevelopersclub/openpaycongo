#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
artifacts="${root}/artifacts/security"
trivy_cache="openpaycongo-security-trivy-cache"
syft_image="anchore/syft@sha256:825cad3a952c87676a6d07e9a3bb05ac9c401d598360070e970aa46d54c1727e"
trivy_image="aquasec/trivy@sha256:bcc376de8d77cfe086a917230e818dc9f8528e3c852f7b1aff648949b6258d1c"
test_image="openpaycongo-server-test:security"
fpm_image="congo-openpay-fpm:security"
nginx_image="congo-openpay-nginx:security"

bash "${root}/scripts/security/security-fast.sh"
mkdir -p "${artifacts}"

docker build --progress=quiet --target test --tag "${test_image}" -f "${root}/server/Dockerfile" "${root}"
docker build --progress=quiet --target production --tag "${fpm_image}" -f "${root}/server/Dockerfile" "${root}"
docker build --progress=quiet --target production --tag "${nginx_image}" -f "${root}/server/docker/nginx.Dockerfile" "${root}"
MSYS_NO_PATHCONV=1 docker run --rm --volume "${root}:/repo:ro" --volume "${artifacts}:/artifacts" "${syft_image}" \
  dir:/repo/server --output cyclonedx-json=/artifacts/openpaycongo-server.cdx.json
MSYS_NO_PATHCONV=1 docker run --rm --volume "${root}:/repo:ro" --volume "${artifacts}:/artifacts" "${syft_image}" \
  dir:/repo/android-client --output cyclonedx-json=/artifacts/openpaycongo-android-client.cdx.json
MSYS_NO_PATHCONV=1 docker run --rm --volume /var/run/docker.sock:/var/run/docker.sock:ro --volume "${artifacts}:/artifacts" "${syft_image}" \
  "${fpm_image}" --output cyclonedx-json=/artifacts/openpaycongo-fpm-production.cdx.json
MSYS_NO_PATHCONV=1 docker run --rm --volume /var/run/docker.sock:/var/run/docker.sock:ro --volume "${artifacts}:/artifacts" "${syft_image}" \
  "${nginx_image}" --output cyclonedx-json=/artifacts/openpaycongo-nginx-production.cdx.json
for image in "${test_image}" "${fpm_image}" "${nginx_image}"; do
  MSYS_NO_PATHCONV=1 docker run --rm --volume /var/run/docker.sock:/var/run/docker.sock:ro --volume "${trivy_cache}:/root/.cache/trivy" "${trivy_image}" \
    image --scanners vuln --severity HIGH,CRITICAL --exit-code 1 --skip-version-check "${image}"
done
