#!/usr/bin/env bash
set -euo pipefail

image="$1"
connection="$2"
port="$3"
barrier_root="$(mktemp -d)"
barrier_volumes=()

cleanup() {
  local status=$?
  if [[ "$status" -ne 0 ]]; then
    find "$barrier_root" -name '*.out' -type f -exec sh -c 'echo "--- $1"; cat "$1"' _ {} \;
  fi
  for barrier_volume in "${barrier_volumes[@]}"; do
    docker volume rm "$barrier_volume" >/dev/null 2>&1 || true
  done
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

reset_database() {
  docker run "${base_args[@]}" "$image" php artisan migrate:fresh --force
}

assert_state() {
  docker run "${base_args[@]}" --env DEPOSIT_TEST_EXPECTED_DEPOSITS="$1" --env DEPOSIT_TEST_EXPECTED_LEDGER_ENTRIES="$2" --env DEPOSIT_TEST_EXPECTED_CREDIT_MINOR="$3" "$image" php tests/Support/assert_provider_deposit_state.php
}

run_pair() {
  local scenario="$1"
  local first_ring="$2"
  local first_active="$3"
  local second_ring="$4"
  local second_active="$5"
  local second_sender="$6"
  local second_reference="$7"
  local barrier="$barrier_root/$scenario"
  local barrier_volume="openpaycongo-deposit-race-$$-$scenario"
  mkdir "$barrier"
  barrier_volumes+=("$barrier_volume")
  docker volume create "$barrier_volume" >/dev/null

  docker run "${base_args[@]}" --volume "$barrier_volume:/barrier" --env DEPOSIT_LOOKUP_TOKEN_KEYS="$first_ring" --env DEPOSIT_LOOKUP_TOKEN_ACTIVE_KEY_ID="$first_active" --env DEPOSIT_TEST_BARRIER_DIRECTORY=//barrier --env DEPOSIT_TEST_WORKER=first "$image" php tests/Support/record_provider_deposit.php >"$barrier/first.out" 2>&1 &
  local first_pid=$!
  docker run "${base_args[@]}" --volume "$barrier_volume:/barrier" --env DEPOSIT_LOOKUP_TOKEN_KEYS="$second_ring" --env DEPOSIT_LOOKUP_TOKEN_ACTIVE_KEY_ID="$second_active" --env DEPOSIT_TEST_BARRIER_DIRECTORY=//barrier --env DEPOSIT_TEST_WORKER=second --env DEPOSIT_TEST_SENDER_IDENTIFIER="$second_sender" --env DEPOSIT_TEST_PROVIDER_REFERENCE="$second_reference" "$image" php tests/Support/record_provider_deposit.php >"$barrier/second.out" 2>&1 &
  local second_pid=$!

  for _ in $(seq 1 300); do
    docker run --rm --volume "$barrier_volume:/barrier" "$image" php -r "exit(file_exists('/barrier/first.ready') && file_exists('/barrier/second.ready') ? 0 : 1);" && break
    sleep 0.1
  done
  docker run --rm --volume "$barrier_volume:/barrier" "$image" php -r "exit(file_exists('/barrier/first.ready') && file_exists('/barrier/second.ready') ? 0 : 1);"
  docker run --rm --volume "$barrier_volume:/barrier" "$image" php -r "touch('/barrier/release');"
  wait "$first_pid"
  wait "$second_pid"

  if [[ "$second_reference" != "" ]]; then
    grep -qx 'recorded' "$barrier/first.out"
    grep -qx 'recorded' "$barrier/second.out"
  elif [[ "$second_sender" == "" ]]; then
    grep -qx 'recorded' "$barrier/first.out" || grep -qx 'recorded' "$barrier/second.out"
    grep -qx 'replayed' "$barrier/first.out" || grep -qx 'replayed' "$barrier/second.out"
  else
    grep -qx 'recorded' "$barrier/first.out" || grep -qx 'recorded' "$barrier/second.out"
    grep -qx 'conflict' "$barrier/first.out" || grep -qx 'conflict' "$barrier/second.out"
  fi

  local expected_deposits=1
  local expected_entries=2
  local expected_credit=12500
  if [[ "$second_reference" != "" ]]; then
    expected_deposits=2
    expected_entries=4
    expected_credit=25000
  fi
  assert_state "$expected_deposits" "$expected_entries" "$expected_credit"
  if [[ "$second_sender" == "" && "$second_reference" == "" ]]; then
    docker run "${base_args[@]}" --env DEPOSIT_LOOKUP_TOKEN_KEYS="$first_ring" --env DEPOSIT_LOOKUP_TOKEN_ACTIVE_KEY_ID="$first_active" "$image" php tests/Support/record_provider_deposit.php | grep -Fx replayed
  fi
  assert_state "$expected_deposits" "$expected_entries" "$expected_credit"
}

previous='{"previous":"previous-deposit-lookup-key-material-32"}'
current='{"current":"current-deposit-lookup-key-material-32"}'
full_ring='{"current":"current-deposit-lookup-key-material-32","previous":"previous-deposit-lookup-key-material-32"}'

reset_database
run_pair same-active-exact "$current" current "$current" current '' ''
reset_database
run_pair conflicting-provider-identity "$current" current "$current" current conflicting-sender ''
reset_database
run_pair mixed-previous-current-ring "$full_ring" previous "$full_ring" current '' ''
reset_database
run_pair fresh-customer-installation "$full_ring" current "$full_ring" current '' fresh-customer-installation-provider-reference
