#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
artifacts="${root}/artifacts/security"
trivy_cache="${artifacts}/trivy-cache"
syft_image="anchore/syft@sha256:825cad3a952c87676a6d07e9a3bb05ac9c401d598360070e970aa46d54c1727e"
trivy_image="aquasec/trivy@sha256:bcc376de8d77cfe086a917230e818dc9f8528e3c852f7b1aff648949b6258d1c"
image="openpaycongo-server:security"

"${root}/scripts/security/security-fast.sh"
mkdir -p "${artifacts}"
mkdir -p "${trivy_cache}"

docker build --target test --tag "${image}" -f "${root}/server/Dockerfile" "${root}"
MSYS_NO_PATHCONV=1 docker run --rm --volume "${root}:/repo:ro" --volume "${artifacts}:/artifacts" "${syft_image}" \
  dir:/repo/server --output cyclonedx-json=/artifacts/openpaycongo-server.cdx.json
MSYS_NO_PATHCONV=1 docker run --rm --volume "${root}:/repo:ro" --volume "${artifacts}:/artifacts" "${syft_image}" \
  dir:/repo/android-client --output cyclonedx-json=/artifacts/openpaycongo-android-client.cdx.json
MSYS_NO_PATHCONV=1 docker run --rm --volume /var/run/docker.sock:/var/run/docker.sock --volume "${trivy_cache}:/root/.cache/trivy" "${trivy_image}" \
  image --severity HIGH,CRITICAL --exit-code 1 "${image}"
