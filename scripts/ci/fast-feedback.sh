#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash scripts/ci/fast-feedback.sh <tier> <component> [focused selector | matrix connection port]

Tiers:
  focused   one changed behavior, selected by a test filter or test path
  local     affected component quality and regression suite
  pr        unconditional pull-request component gate
  main      immutable-artifact main-branch component gate (not implemented)
  deploy    exact-artifact promotion and verification gate (not implemented)
  scheduled compatibility, performance, migration, fuzz, or soak component gate

Components: contracts, laravel, flutter, postgres-migration, deposit-concurrency, security
USAGE
}

die() { printf '%s\n' "$*" >&2; exit 64; }
require_selector() { [[ $# -eq 1 && -n "$1" ]] || die 'focused checks require exactly one test selector'; }
require_test_path() {
  local component="$1" selector="$2" pattern="$3" root="$4"
  require_selector "$selector"
  [[ "$selector" != -* && "$selector" != *'..'* && "$selector" == $pattern && -f "$root/$selector" ]] \
    || die "focused $component requires an existing $pattern test path"
}
require_laravel_filter() {
  require_selector "$1"
  [[ "$1" != -* && "$1" =~ ^[A-Za-z_\\][A-Za-z0-9_\\]*$ ]] \
    || die 'focused laravel requires a PHPUnit class-name filter'
}
run_contracts() { docker build --target test -f docs/Dockerfile .; }
run_laravel_quality_and_tests() { docker build --target test -f server/Dockerfile .; }
run_flutter_quality_and_tests() {
  docker build --target analyze -f android-client/Dockerfile.ci android-client
  docker build --target test -f android-client/Dockerfile.ci android-client
}
run_security_fast() {
  bash scripts/security/security-fast.sh
  bash scripts/security/security-history.sh
  bash scripts/security/verify-secret-scanner.sh
  bash scripts/security/verify-enforced-controls.sh
}

run_laravel_pr() (
  export OPENPAY_APP_KEY='base64:MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE='
  export OPENPAY_APP_URL='https://openpay.test'
  export OPENPAY_PASSKEY_RP_ID='openpay.test'
  export OPENPAY_PASSKEY_ALLOWED_ORIGINS='["https://openpay.test"]'
  export OPENPAY_PASSKEY_USER_HANDLE_SECRET='ci-passkey-user-handle-secret-at-least-32-characters'
  export OPENPAY_DB_PASSWORD='ci-compose-validation-only'
  export DEPOSIT_LOOKUP_TOKEN_KEY='ci-compose-deposit-lookup-token-only'
  created_markers=()
  created_directories=()
  cleanup_laravel_markers() {
    local path
    for path in "${created_markers[@]}"; do rm -f "$path"; done
    for path in "${created_directories[@]}"; do rmdir "$path" 2>/dev/null || true; done
  }
  trap cleanup_laravel_markers EXIT
  docker compose config --quiet
  for secret in OPENPAY_APP_KEY OPENPAY_DB_PASSWORD DEPOSIT_LOOKUP_TOKEN_KEY; do
    if env -u "$secret" docker compose config --quiet >/dev/null 2>&1; then die 'Compose accepted a missing required secret.'; fi
  done
  run_laravel_quality_and_tests
  local marker directory
  for marker in server/vendor/.openpay-host-dependency-marker server/node_modules/.openpay-host-dependency-marker; do
    if [[ ! -e "$marker" ]]; then
      directory="$(dirname "$marker")"
      if [[ ! -d "$directory" ]]; then
        mkdir -p "$directory"
        created_directories+=("$directory")
      fi
      touch "$marker"
      created_markers+=("$marker")
    fi
  done
  docker build --target production-contract -f server/Dockerfile .
  docker build --target production-contract -f server/docker/nginx.Dockerfile .
  docker build --target production --tag congo-openpay-fpm:ci -f server/Dockerfile .
  docker build --target production --tag congo-openpay-nginx:ci -f server/docker/nginx.Dockerfile .
  for image in congo-openpay-fpm:ci congo-openpay-nginx:ci; do
    MSYS_NO_PATHCONV=1 docker run --rm -v /var/run/docker.sock:/var/run/docker.sock:ro aquasec/trivy@sha256:bcc376de8d77cfe086a917230e818dc9f8528e3c852f7b1aff648949b6258d1c image --scanners vuln --severity HIGH,CRITICAL --exit-code 1 --skip-version-check "$image"
  done
)

run_postgres_migration() {
  docker build --target quality --tag openpaycongo-server-postgres -f server/Dockerfile .
  docker run --rm --network host --env APP_ENV=testing --env APP_KEY=base64:MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE= --env DB_CONNECTION=pgsql --env DB_HOST=127.0.0.1 --env DB_PORT=5432 --env DB_DATABASE=openpaycongo --env DB_USERNAME=openpay --env DB_PASSWORD=openpay openpaycongo-server-postgres php artisan migrate:fresh --force
  docker run --rm --network host --env PGPASSWORD=openpay postgres:16-alpine@sha256:cf78e76683b9ca8c5733cbbdce6c9262b45b6767934dd0a95e671f9a0fc20685 \
    psql --host=127.0.0.1 --port=5432 --username=openpay --dbname=openpaycongo --tuples-only --no-align \
    --command "select constraint_name || ':' || constraint_type from information_schema.table_constraints where table_schema = 'public' and table_name = 'deposits' and constraint_name in ('deposits_reverses_deposit_id_foreign', 'deposits_reverses_deposit_id_unique') order by constraint_name" \
    | grep -Fx 'deposits_reverses_deposit_id_foreign:FOREIGN KEY'
  docker run --rm --network host --env PGPASSWORD=openpay postgres:16-alpine@sha256:cf78e76683b9ca8c5733cbbdce6c9262b45b6767934dd0a95e671f9a0fc20685 \
    psql --host=127.0.0.1 --port=5432 --username=openpay --dbname=openpaycongo --tuples-only --no-align \
    --command "select constraint_name || ':' || constraint_type from information_schema.table_constraints where table_schema = 'public' and table_name = 'deposits' and constraint_name in ('deposits_reverses_deposit_id_foreign', 'deposits_reverses_deposit_id_unique') order by constraint_name" \
    | grep -Fx 'deposits_reverses_deposit_id_unique:UNIQUE'
}

run_deposit_concurrency() {
  [[ $# -eq 2 ]] || die 'deposit-concurrency requires a connection and port'
  local connection="$1" port="$2"
  docker build --target quality --tag openpaycongo-server-concurrency -f server/Dockerfile .
  bash server/tests/Support/run_provider_deposit_concurrency_matrix.sh openpaycongo-server-concurrency "$connection" "$port"
  bash server/tests/Support/run_payment_request_concurrency_matrix.sh openpaycongo-server-concurrency "$connection" "$port"
}

tier="${1:-}"; component="${2:-}"; shift $(( $# >= 2 ? 2 : $# ))
case "$tier" in
  focused)
    case "$component" in
      contracts) require_test_path contracts "${1:-}" 'docs/*.test.mjs' .; docker build --target focused --build-arg TEST_PATH="$1" -f docs/Dockerfile . ;;
      laravel) require_laravel_filter "${1:-}"; docker build --target focused --build-arg TEST_FILTER="$1" -f server/Dockerfile . ;;
      flutter) require_test_path flutter "${1:-}" 'test/*_test.dart' android-client; docker build --target focused --build-arg TEST_PATH="$1" -f android-client/Dockerfile.ci android-client ;;
      *) die 'focused supports contracts, laravel, or flutter' ;;
    esac ;;
  local)
    case "$component" in contracts) run_contracts ;; laravel) run_laravel_quality_and_tests ;; flutter) run_flutter_quality_and_tests ;; *) die 'local supports contracts, laravel, or flutter' ;; esac ;;
  pr)
    case "$component" in
      contracts) run_contracts ;;
      laravel) run_laravel_pr ;;
      flutter) run_flutter_quality_and_tests; docker build --target artifact --output type=local,dest=android-client/build/ci -f android-client/Dockerfile.ci android-client ;;
      postgres-migration) run_postgres_migration ;;
      deposit-concurrency) run_deposit_concurrency "$@" ;;
      security) run_security_fast ;;
      *) die 'PR component is unknown' ;;
    esac ;;
  main) die 'T3 immutable artifact publication and provenance are not implemented; see ADR 006.' ;;
  deploy) die 'T4 exact-artifact promotion and production-like verification are not implemented; see ADR 006.' ;;
  scheduled)
    case "$component" in security) bash scripts/security/security-full.sh; bash scripts/security/verify-full-controls.sh ;; *) die 'scheduled component is unknown' ;; esac ;;
  *) usage; exit 64 ;;
esac
