#!/usr/bin/env bash
set -euo pipefail

image="$1"
connection="$2"
port="$3"
barrier_root="$(mktemp -d)"
barrier_volume="openpaycongo-payment-request-race-$$"
barrier_volumes=("$barrier_volume")

cleanup() {
  local status=$?
  if [[ "$status" -ne 0 ]]; then
    find "$barrier_root" -name '*.out' -type f -exec sh -c 'echo "--- $1"; cat "$1"' _ {} \;
  fi
  for volume in "${barrier_volumes[@]}"; do
    docker volume rm "$volume" >/dev/null 2>&1 || true
  done
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
customer_id="$(docker run "${base_args[@]}" "$image" php tests/Support/prepare_payment_request_credit.php)"
mkdir "$barrier_root/race"
docker volume create "$barrier_volume" >/dev/null

for worker in first second; do
  docker run "${base_args[@]}" --volume "$barrier_volume:/barrier" \
    --env PAYMENT_REQUEST_TEST_BARRIER_DIRECTORY=/barrier \
    --env PAYMENT_REQUEST_TEST_WORKER="$worker" \
    --env PAYMENT_REQUEST_TEST_TRANSACTION_BARRIER=1 \
    --env PAYMENT_REQUEST_TEST_IDEMPOTENCY_KEY="payment-request-race-$worker" \
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
for _ in $(seq 1 300); do docker run --rm --volume "$barrier_volume:/barrier" "$image" php -r "exit(file_exists('/barrier/first.transaction-ready') && file_exists('/barrier/second.transaction-ready') ? 0 : 1);" && break; sleep 0.1; done
docker run --rm --volume "$barrier_volume:/barrier" "$image" php -r "exit(file_exists('/barrier/first.transaction-ready') && file_exists('/barrier/second.transaction-ready') ? 0 : 1);"
docker run --rm --volume "$barrier_volume:/barrier" "$image" php -r "touch('/barrier/transaction-release');"
wait "$first_pid"
wait "$second_pid"

grep -Fx charged "$barrier_root/race/first.out" || grep -Fx charged "$barrier_root/race/second.out"
grep -Fx pending "$barrier_root/race/first.out" || grep -Fx pending "$barrier_root/race/second.out"
docker run "${base_args[@]}" --env PAYMENT_REQUEST_TEST_CUSTOMER_ID="$customer_id" --env PAYMENT_REQUEST_TEST_EXPECTED_CHARGED=1 --env PAYMENT_REQUEST_TEST_EXPECTED_PENDING=1 --env PAYMENT_REQUEST_TEST_EXPECTED_AVAILABLE=0 "$image" php tests/Support/assert_payment_request_state.php

# A second overlapped pair uses the same opaque key. Both callers must receive
# the one persisted pending request instead of creating a second debit/request.
same_key_volume="${barrier_volume}-same-key"
barrier_volumes+=("$same_key_volume")
docker volume create "$same_key_volume" >/dev/null
rotation_ring='{"v1":"testing-deposit-lookup-key-material-32","previous":"pppppppppppppppppppppppppppppppp","current":"cccccccccccccccccccccccccccccccc"}'
for worker in first second; do
  active_key_id=previous
  if [[ "$worker" == second ]]; then active_key_id=current; fi
  docker run "${base_args[@]}" --volume "$same_key_volume:/barrier" \
    --env PAYMENT_REQUEST_TEST_BARRIER_DIRECTORY=/barrier \
    --env PAYMENT_REQUEST_TEST_WORKER="$worker" \
    --env PAYMENT_REQUEST_TEST_TRANSACTION_BARRIER=1 \
    --env PAYMENT_REQUEST_IDEMPOTENCY_KEYS="$rotation_ring" \
    --env PAYMENT_REQUEST_IDEMPOTENCY_ACTIVE_KEY_ID="$active_key_id" \
    --env PAYMENT_REQUEST_TEST_IDEMPOTENCY_KEY="same-opaque-replay-key" \
    --env PAYMENT_REQUEST_TEST_CUSTOMER_ID="$customer_id" \
    "$image" php tests/Support/create_payment_request.php >"$barrier_root/race/same-$worker.out" 2>&1 &
  eval "same_${worker}_pid=$!"
done
for _ in $(seq 1 300); do
  docker run --rm --volume "$same_key_volume:/barrier" "$image" php -r "exit(file_exists('/barrier/first.ready') && file_exists('/barrier/second.ready') ? 0 : 1);" && break
  sleep 0.1
done
docker run --rm --volume "$same_key_volume:/barrier" "$image" php -r "exit(file_exists('/barrier/first.ready') && file_exists('/barrier/second.ready') ? 0 : 1);"
docker run --rm --volume "$same_key_volume:/barrier" "$image" php -r "touch('/barrier/release');"
for _ in $(seq 1 300); do docker run --rm --volume "$same_key_volume:/barrier" "$image" php -r "exit(file_exists('/barrier/first.transaction-ready') && file_exists('/barrier/second.transaction-ready') ? 0 : 1);" && break; sleep 0.1; done
docker run --rm --volume "$same_key_volume:/barrier" "$image" php -r "exit(file_exists('/barrier/first.transaction-ready') && file_exists('/barrier/second.transaction-ready') ? 0 : 1);"
docker run --rm --volume "$same_key_volume:/barrier" "$image" php -r "touch('/barrier/transaction-release');"
wait "$same_first_pid"
wait "$same_second_pid"
grep -Fx pending "$barrier_root/race/same-first.out"
grep -Fx pending "$barrier_root/race/same-second.out"
docker run "${base_args[@]}" --env PAYMENT_REQUEST_TEST_CUSTOMER_ID="$customer_id" --env PAYMENT_REQUEST_TEST_EXPECTED_CHARGED=1 --env PAYMENT_REQUEST_TEST_EXPECTED_PENDING=2 --env PAYMENT_REQUEST_TEST_EXPECTED_AVAILABLE=0 "$image" php tests/Support/assert_payment_request_state.php
docker volume rm "$same_key_volume" >/dev/null

# Two deposits overlap while allocating a FIFO queue. The fixture also includes
# an expired CDF request and a USD request, which must remain untouched.
docker run "${base_args[@]}" "$image" php artisan migrate:fresh --force
IFS=, read -r deposit_one deposit_two <<<"$(docker run "${base_args[@]}" "$image" php tests/Support/prepare_payment_request_allocation_race.php)"
allocation_volume="${barrier_volume}-allocation"
barrier_volumes+=("$allocation_volume")
docker volume create "$allocation_volume" >/dev/null
for pair in "first:$deposit_one" "second:$deposit_two"; do
  worker="${pair%%:*}"; deposit_id="${pair##*:}"
  docker run "${base_args[@]}" --volume "$allocation_volume:/barrier" --env PAYMENT_REQUEST_TEST_BARRIER_DIRECTORY=/barrier --env PAYMENT_REQUEST_TEST_WORKER="$worker" --env PAYMENT_REQUEST_TEST_DEPOSIT_ID="$deposit_id" "$image" php tests/Support/allocate_pending_payment_requests.php >"$barrier_root/race/allocation-$worker.out" 2>&1 &
  eval "allocation_${worker}_pid=$!"
done
for _ in $(seq 1 300); do docker run --rm --volume "$allocation_volume:/barrier" "$image" php -r "exit(file_exists('/barrier/first.ready') && file_exists('/barrier/second.ready') ? 0 : 1);" && break; sleep 0.1; done
docker run --rm --volume "$allocation_volume:/barrier" "$image" php -r "exit(file_exists('/barrier/first.ready') && file_exists('/barrier/second.ready') ? 0 : 1);"
docker run --rm --volume "$allocation_volume:/barrier" "$image" php -r "touch('/barrier/release');"
for _ in $(seq 1 300); do docker run --rm --volume "$allocation_volume:/barrier" "$image" php -r "exit(file_exists('/barrier/first.transaction-ready') && file_exists('/barrier/second.transaction-ready') ? 0 : 1);" && break; sleep 0.1; done
docker run --rm --volume "$allocation_volume:/barrier" "$image" php -r "exit(file_exists('/barrier/first.transaction-ready') && file_exists('/barrier/second.transaction-ready') ? 0 : 1);"
docker run --rm --volume "$allocation_volume:/barrier" "$image" php -r "touch('/barrier/transaction-release');"
wait "$allocation_first_pid"; wait "$allocation_second_pid"
grep -Fx allocated "$barrier_root/race/allocation-first.out"; grep -Fx allocated "$barrier_root/race/allocation-second.out"
docker run "${base_args[@]}" "$image" php tests/Support/assert_payment_request_allocation_race.php
docker volume rm "$allocation_volume" >/dev/null

# Two different provider credits are reversed together before any customer-credit
# row exists. Both reversals must commit through the unique-row contention.
docker run "${base_args[@]}" "$image" php artisan migrate:fresh --force
IFS=, read -r reversal_deposit_one reversal_deposit_two <<<"$(docker run "${base_args[@]}" "$image" php tests/Support/prepare_payment_request_reversal_race.php)"
reversal_volume="${barrier_volume}-reversal"
barrier_volumes+=("$reversal_volume")
docker volume create "$reversal_volume" >/dev/null
for pair in "first:$reversal_deposit_one" "second:$reversal_deposit_two"; do
  worker="${pair%%:*}"; deposit_id="${pair##*:}"
  docker run "${base_args[@]}" --volume "$reversal_volume:/barrier" --env PAYMENT_REQUEST_TEST_BARRIER_DIRECTORY=/barrier --env PAYMENT_REQUEST_TEST_WORKER="$worker" --env PAYMENT_REQUEST_TEST_DEPOSIT_ID="$deposit_id" "$image" php tests/Support/reverse_payment_request_credit.php >"$barrier_root/race/reversal-$worker.out" 2>&1 &
  eval "reversal_${worker}_pid=$!"
done
for _ in $(seq 1 300); do docker run --rm --volume "$reversal_volume:/barrier" "$image" php -r "exit(file_exists('/barrier/first.ready') && file_exists('/barrier/second.ready') ? 0 : 1);" && break; sleep 0.1; done
docker run --rm --volume "$reversal_volume:/barrier" "$image" php -r "exit(file_exists('/barrier/first.ready') && file_exists('/barrier/second.ready') ? 0 : 1);"
docker run --rm --volume "$reversal_volume:/barrier" "$image" php -r "touch('/barrier/release');"
wait "$reversal_first_pid"; wait "$reversal_second_pid"
grep -Fx reversed "$barrier_root/race/reversal-first.out"; grep -Fx reversed "$barrier_root/race/reversal-second.out"
docker run "${base_args[@]}" "$image" php tests/Support/assert_payment_request_reversal_race.php
docker volume rm "$reversal_volume" >/dev/null

# A recovery job and the original job overlap. One durable lease must be the
# only callback boundary crossing while both workers still finish cleanly.
docker run "${base_args[@]}" "$image" php artisan migrate:fresh --force
callback_delivery_id="$(docker run "${base_args[@]}" "$image" php tests/Support/prepare_payment_request_callback_race.php)"
callback_volume="${barrier_volume}-callback"
barrier_volumes+=("$callback_volume")
docker volume create "$callback_volume" >/dev/null
for worker in first second; do
  docker run "${base_args[@]}" --volume "$callback_volume:/barrier" --env PAYMENT_REQUEST_TEST_BARRIER_DIRECTORY=/barrier --env PAYMENT_REQUEST_TEST_WORKER="$worker" --env PAYMENT_REQUEST_TEST_DELIVERY_ID="$callback_delivery_id" "$image" php tests/Support/dispatch_payment_request_allocation.php >"$barrier_root/race/callback-$worker.out" 2>&1 &
  eval "callback_${worker}_pid=$!"
done
for _ in $(seq 1 300); do docker run --rm --volume "$callback_volume:/barrier" "$image" php -r "exit(file_exists('/barrier/first.ready') && file_exists('/barrier/second.ready') ? 0 : 1);" && break; sleep 0.1; done
docker run --rm --volume "$callback_volume:/barrier" "$image" php -r "exit(file_exists('/barrier/first.ready') && file_exists('/barrier/second.ready') ? 0 : 1);"
docker run --rm --volume "$callback_volume:/barrier" "$image" php -r "touch('/barrier/release');"
wait "$callback_first_pid"; wait "$callback_second_pid"
grep -Fx handled "$barrier_root/race/callback-first.out"; grep -Fx handled "$barrier_root/race/callback-second.out"
docker run "${base_args[@]}" --volume "$callback_volume:/barrier" --env PAYMENT_REQUEST_TEST_BARRIER_DIRECTORY=/barrier --env PAYMENT_REQUEST_TEST_DELIVERY_ID="$callback_delivery_id" "$image" php tests/Support/assert_payment_request_callback_race.php
docker volume rm "$callback_volume" >/dev/null
docker run "${base_args[@]}" "$image" php tests/Support/assert_payment_request_upgrade_reversal.php
# Exercise the FIFO tie-break, expiry, all-or-nothing, currency isolation,
# idempotency replay, and durable-delivery regressions against this same dialect.
docker run "${base_args[@]}" "$image" php artisan test --filter=PaymentRequestTest
