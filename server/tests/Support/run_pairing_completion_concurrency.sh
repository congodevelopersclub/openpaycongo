#!/usr/bin/env bash
set -euo pipefail

image="$1"
connection="$2"
port="$3"
barrier_root="$(mktemp -d)"
barrier_volume="openpaycongo-pairing-race-$$"

cleanup() {
  local status=$?
  docker volume rm "$barrier_volume" >/dev/null 2>&1 || true
  rm -rf "$barrier_root"
  exit "$status"
}
trap cleanup EXIT

base_args=(--rm --network host
  --env APP_ENV=testing
  --env APP_KEY=base64:MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE=
  --env DB_CONNECTION="$connection"
  --env DB_HOST=127.0.0.1
  --env DB_PORT="$port"
  --env DB_DATABASE=openpaycongo
  --env DB_USERNAME=openpay
  --env DB_PASSWORD=openpay)

docker run "${base_args[@]}" "$image" php artisan migrate:fresh --force
docker run "${base_args[@]}" "$image" php tests/Support/seed_pairing_completion_intent.php
docker volume create "$barrier_volume" >/dev/null

docker run "${base_args[@]}" --volume "$barrier_volume:/barrier" --env PAIRING_TEST_BARRIER_DIRECTORY=/barrier --env PAIRING_TEST_WORKER=first "$image" php tests/Support/reserve_pairing_completion.php >"$barrier_root/first.out" 2>&1 &
first_pid=$!
docker run "${base_args[@]}" --volume "$barrier_volume:/barrier" --env PAIRING_TEST_BARRIER_DIRECTORY=/barrier --env PAIRING_TEST_WORKER=second "$image" php tests/Support/reserve_pairing_completion.php >"$barrier_root/second.out" 2>&1 &
second_pid=$!

docker run --rm --volume "$barrier_volume:/barrier" "$image" php -r '$deadline = microtime(true) + 30; while (! (file_exists("/barrier/first.ready") && file_exists("/barrier/second.ready"))) { if (microtime(true) >= $deadline) { exit(1); } usleep(100000); }'
docker run --rm --volume "$barrier_volume:/barrier" "$image" php -r "touch('/barrier/release');"
wait "$first_pid"
wait "$second_pid"

grep -hFx reserved "$barrier_root/first.out" "$barrier_root/second.out"
grep -hFx unavailable "$barrier_root/first.out" "$barrier_root/second.out"
docker run "${base_args[@]}" "$image" php tests/Support/assert_pairing_completion_reservation_state.php
