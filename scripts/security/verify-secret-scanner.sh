#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "${root}/artifacts/security"
fixture="$(mktemp -d "${root}/artifacts/security/secret-history-fixture.XXXXXX")"
result="${fixture}/gitleaks-output.txt"
trap 'rm -rf "${fixture}"' EXIT
image="zricethezav/gitleaks@sha256:b5918eb91b8d2473cec722f066abb4352e4ffdc4ec9f4283ec143aba9ec9ebc4"

# Assemble the synthetic token at runtime so the test itself is not a finding.
# Commit then remove it: git-aware scanning must still reject that history.
git -C "${fixture}" init --quiet
git -C "${fixture}" config user.email 'security-gate@example.test'
git -C "${fixture}" config user.name 'Security Gate'
printf '%s%s\n' \
  'history_secret = security_gate_history_' 'aB3dE5fG7hI9jK1lM2nO4pQ6rS8tU0vW' > "${fixture}/synthetic-secret.env"
git -C "${fixture}" add synthetic-secret.env
git -C "${fixture}" commit --quiet --message 'seed synthetic secret'
rm "${fixture}/synthetic-secret.env"
git -C "${fixture}" add --all
git -C "${fixture}" commit --quiet --message 'remove synthetic secret'

if MSYS_NO_PATHCONV=1 docker run --rm --volume "${fixture}:/fixture:ro" --volume "${root}/.gitleaks.toml:/config/gitleaks.toml:ro" "${image}" \
  git --config=/config/gitleaks.toml --log-opts=--all --redact --exit-code=1 /fixture > "${result}" 2>&1; then
  echo 'gitleaks did not reject the seeded synthetic secret in git history' >&2
  exit 1
fi

if ! grep --quiet 'leaks found: 1' "${result}"; then
  echo 'gitleaks failed without reporting the seeded history finding' >&2
  cat "${result}" >&2
  exit 1
fi

echo 'seeded secret detection passed'
