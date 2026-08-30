#!/bin/sh
set -eu
docker_bin="${OPENPAY_DOCKER_BIN:-docker}"
"$docker_bin" compose stop nginx php queue scheduler
if ! "$docker_bin" compose run --rm migrate; then
  exit 1
fi
"$docker_bin" compose up -d --force-recreate php nginx queue scheduler
