#!/usr/bin/env bash
set -euo pipefail

image="$1"
connection="$2"
port="$3"
barrier_root="$(mktemp -d)"
barrier_volume="openpaycongo-payment-request-race-$$"

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
  --env DB_CONNECTION="$connection"
  --env DB_HOST=127.0.0.1
  --env DB_PORT="$port"
  --env DB_DATABASE=openpaycongo
  --env DB_USERNAME=openpay
  --env DB_PASSWORD=openpay)

docker run "${base_args[@]}" "$image" php artisan migrate:fresh --force
customer_id="$(docker run "${base_args[@]}" "$image" php tests/Support/prepare_payment_request_credit.php)"
mkdir "$barrier_root/race"
docker volume create "$barrier_volume" >/dev/null

for worker in first second; do
  docker run "${base_args[@]}" --volume "$barrier_volume:/barrier" \
    --env PAYMENT_REQUEST_TEST_BARRIER_DIRECTORY=/barrier \
    --env PAYMENT_REQUEST_TEST_WORKER="$worker" \
    --env PAYMENT_REQUEST_TEST_CUSTOMER_ID="$customer_id" \
    "$image" php tests/Support/create_payment_request.php >"$barrier_root/race/$worker.out" 2>&1 &
  eval "${worker}_pid=$!"
done

for _ in $(seq 1 300); do
  docker run --rm --volume "$barrier_volume:/barrier" "$image" php -r "exit(file_exists('/barrier/first.ready') && file_exists('/barrier/second.ready') ? 0 : 1);" && break
  sleep 0.1
done
docker run --rm --volume "$barrier_volume:/barrier" "$image" php -r "exit(file_exists('/barrier/first.ready') && file_exists('/barrier/second.ready') ? 0 : 1);"
docker run --rm --volume "$barrier_volume:/barrier" "$image" php -r "touch('/barrier/release');"
wait "$first_pid"
wait "$second_pid"

grep -Fx charged "$barrier_root/race/first.out" || grep -Fx charged "$barrier_root/race/second.out"
grep -Fx pending "$barrier_root/race/first.out" || grep -Fx pending "$barrier_root/race/second.out"
docker run "${base_args[@]}" --env PAYMENT_REQUEST_TEST_CUSTOMER_ID="$customer_id" --env PAYMENT_REQUEST_TEST_EXPECTED_CHARGED=1 --env PAYMENT_REQUEST_TEST_EXPECTED_PENDING=1 --env PAYMENT_REQUEST_TEST_EXPECTED_AVAILABLE=0 "$image" php tests/Support/assert_payment_request_state.php
