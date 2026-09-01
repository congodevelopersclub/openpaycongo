#!/usr/bin/env bash
set -euo pipefail

image="$1"
connection="$2"
port="$3"
barrier_root="$(mktemp -d)"
barrier_volume="openpaycongo-mobile-envelope-race-$$"

cleanup() {
  local status=$?
  if [[ "$status" -ne 0 ]]; then
    find "$barrier_root" -name '*.out' -type f -exec sh -c 'echo "--- $1"; cat "$1"' _ {} \;
  fi
  docker volume rm "$barrier_volume" >/dev/null 2>&1 || true
  rm -rf "$barrier_root"
  exit "$status"
}
trap cleanup EXIT

base_args=(--rm --network host
  --env APP_ENV=testing
  --env APP_KEY=base64:MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE=
  --env DEPOSIT_LOOKUP_TOKEN_KEY=testing-deposit-lookup-key-material-32
  --env DB_CONNECTION="$connection"
  --env DB_HOST=127.0.0.1
  --env DB_PORT="$port"
  --env DB_DATABASE=openpaycongo
  --env DB_USERNAME=openpay
  --env DB_PASSWORD=openpay)

docker run "${base_args[@]}" "$image" php artisan migrate:fresh --force
docker run "${base_args[@]}" "$image" php tests/Support/seed_mobile_envelope_installation.php
docker volume create "$barrier_volume" >/dev/null

docker run "${base_args[@]}" --volume "$barrier_volume:/barrier" --env MOBILE_ENVELOPE_TEST_BARRIER_DIRECTORY=/barrier --env MOBILE_ENVELOPE_TEST_WORKER=first "$image" php tests/Support/submit_mobile_envelope.php >"$barrier_root/first.out" 2>&1 &
first_pid=$!
docker run "${base_args[@]}" --volume "$barrier_volume:/barrier" --env MOBILE_ENVELOPE_TEST_BARRIER_DIRECTORY=/barrier --env MOBILE_ENVELOPE_TEST_WORKER=second "$image" php tests/Support/submit_mobile_envelope.php >"$barrier_root/second.out" 2>&1 &
second_pid=$!

for _ in $(seq 1 300); do
  docker run --rm --volume "$barrier_volume:/barrier" "$image" php -r "exit(file_exists('/barrier/first.ready') && file_exists('/barrier/second.ready') ? 0 : 1);" && break
  sleep 0.1
done
docker run --rm --volume "$barrier_volume:/barrier" "$image" php -r "exit(file_exists('/barrier/first.ready') && file_exists('/barrier/second.ready') ? 0 : 1);"
docker run --rm --volume "$barrier_volume:/barrier" "$image" php -r "touch('/barrier/release');"
wait "$first_pid"
wait "$second_pid"

grep -hFx created "$barrier_root/first.out" "$barrier_root/second.out" | wc -l | tr -d '[:space:]' | grep -Fx 1
grep -hFx unavailable "$barrier_root/first.out" "$barrier_root/second.out" | wc -l | tr -d '[:space:]' | grep -Fx 1
docker run "${base_args[@]}" "$image" php tests/Support/assert_mobile_envelope_counter_state.php
docker run "${base_args[@]}" "$image" php tests/Support/submit_mobile_envelope.php | grep -Fx unavailable
docker run "${base_args[@]}" "$image" php tests/Support/assert_mobile_envelope_counter_state.php
