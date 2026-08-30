#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gitleaks_image="zricethezav/gitleaks@sha256:b5918eb91b8d2473cec722f066abb4352e4ffdc4ec9f4283ec143aba9ec9ebc4"
trivy_image="aquasec/trivy@sha256:bcc376de8d77cfe086a917230e818dc9f8528e3c852f7b1aff648949b6258d1c"
trivy_cache="${root}/artifacts/security/trivy-cache"

mkdir -p "${trivy_cache}"

MSYS_NO_PATHCONV=1 docker run --rm --volume "${root}:/repo:ro" --workdir /repo "${gitleaks_image}" \
  dir --config=/repo/.gitleaks.toml --redact --exit-code=1 /repo

# Trivy reads only dependency manifests and lockfiles mounted above. Its database
# is downloaded into the disposable container; repository data stays local.
MSYS_NO_PATHCONV=1 docker run --rm --volume "${root}:/repo:ro" --volume "${trivy_cache}:/root/.cache/trivy" --workdir /repo "${trivy_image}" \
  fs --scanners vuln --include-dev-deps --severity HIGH,CRITICAL --exit-code 1 server
MSYS_NO_PATHCONV=1 docker run --rm --volume "${root}:/repo:ro" --volume "${trivy_cache}:/root/.cache/trivy" --workdir /repo "${trivy_image}" \
  fs --scanners vuln --severity HIGH,CRITICAL --exit-code 1 android-client

docker build --target test -f "${root}/server/Dockerfile" "${root}"
docker build --target security -f "${root}/server/Dockerfile" "${root}"
docker build --target analyze -f "${root}/android-client/Dockerfile.ci" "${root}/android-client"
