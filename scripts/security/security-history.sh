#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
image="zricethezav/gitleaks@sha256:b5918eb91b8d2473cec722f066abb4352e4ffdc4ec9f4283ec143aba9ec9ebc4"
result="$(mktemp)"
trap 'rm -f "${result}"' EXIT

# Git-aware mode examines tracked history, including secrets removed in the
# current checkout. The workflow checks out full history before invoking it.
if ! MSYS_NO_PATHCONV=1 docker run --rm --volume "${root}:/repo:ro" --workdir /repo "${image}" \
  git --config=/repo/.gitleaks.toml --log-opts=--all --redact --exit-code=1 /repo > "${result}" 2>&1; then
  cat "${result}" >&2
  exit 1
fi

if grep --quiet -E 'partial scan|failed to scan Git repository' "${result}"; then
  cat "${result}" >&2
  exit 1
fi

cat "${result}"
