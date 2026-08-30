#!/usr/bin/env bash
set -euo pipefail

cleanup() {
  docker compose -f compose.browser.yaml down --volumes --remove-orphans
}

trap cleanup EXIT
docker compose -f compose.browser.yaml up --build --abort-on-container-exit --exit-code-from browser
