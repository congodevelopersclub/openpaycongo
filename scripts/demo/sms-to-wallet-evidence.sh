#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

started_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
evidence_root="${1:-${EVIDENCE_DIR:-artifacts/sms-to-wallet-evidence}}"
if [[ "$evidence_root" != /* ]]; then
  evidence_root="$repo_root/$evidence_root"
fi
evidence_dir="$evidence_root/$run_id"
mkdir -p "$evidence_dir"
summary="$evidence_dir/summary.tsv"
commit="$(git rev-parse HEAD)"
if [[ -z "$(git status --porcelain)" ]]; then
  working_tree="clean"
else
  working_tree="dirty"
fi

printf 'kind\tname\tvalue\tstarted_utc\tended_utc\texit_status\n' > "$summary"
printf 'metadata\tcommit\t%s\t\t\t\n' "$commit" >> "$summary"
printf 'metadata\tworking_tree\t%s\t\t\t\n' "$working_tree" >> "$summary"
printf 'metadata\tstarted_utc\t%s\t\t\t\n' "$started_utc" >> "$summary"
parser_public_key="${OPENPAY_OPERATOR_PATTERN_SIGNING_PUBLIC_KEY:-}"
if [[ ! "$parser_public_key" =~ ^[A-Za-z0-9_-]{43}$ ]]; then
  printf 'Set OPENPAY_OPERATOR_PATTERN_SIGNING_PUBLIC_KEY to the existing parser authority public key before building a runnable SMS demo APK.\n' >&2
  exit 64
fi
printf 'metadata\tparser_signing_public_key\t%s\t\t\t\n' "$parser_public_key" >> "$summary"

failures=0
last_exit_status=0
run_gate() {
  local gate="$1"
  shift
  local gate_start gate_end status
  gate_start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'Running %s\n' "$gate"
  if "$@" >/dev/null 2>&1; then
    status=0
  else
    status=$?
    failures=$((failures + 1))
  fi
  gate_end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  last_exit_status="$status"
  printf 'gate\t%s\t\t%s\t%s\t%s\n' "$gate" "$gate_start" "$gate_end" "$status" >> "$summary"
  printf '  exit status: %s\n' "$status"
}

ci=(bash scripts/ci/fast-feedback.sh)
run_gate focused_mobile_deposit "${ci[@]}" focused laravel MobileDepositCreditWorkflowTest
run_gate focused_sms_parser "${ci[@]}" focused laravel SmsParserEvidenceTest
run_gate focused_sms_envelope "${ci[@]}" focused laravel SmsDepositEnvelopeIntegrationTest
run_gate focused_customer_wallet "${ci[@]}" focused laravel CustomerWalletApiTest
run_gate focused_wallet_webhook "${ci[@]}" focused laravel WalletWebhookDeliveryTest
run_gate focused_wallet_webhook_receiver "${ci[@]}" focused laravel WalletWebhookReceiverIntegrationTest
run_gate focused_sms_to_wallet_end_to_end "${ci[@]}" focused laravel SmsToWalletEndToEndTest
run_gate full_laravel_local "${ci[@]}" local laravel
run_gate full_flutter_local "${ci[@]}" local flutter
run_gate flutter_native_and_debug_apk "${ci[@]}" pr flutter

apk="android-client/build/ci/app-debug.apk"
if [[ "$last_exit_status" == 0 && -f "$apk" ]]; then
  apk_hash="$(sha256sum "$apk" | cut -d ' ' -f 1)"
  apk_size="$(wc -c < "$apk" | tr -d '[:space:]')"
  printf 'artifact\tapk_path\t%s\t\t\t\n' "$apk" >> "$summary"
  printf 'artifact\tapk_sha256\t%s\t\t\t\n' "$apk_hash" >> "$summary"
  printf 'artifact\tapk_bytes\t%s\t\t\t\n' "$apk_size" >> "$summary"
else
  printf 'artifact\tapk\tmissing\t\t\t1\n' >> "$summary"
  failures=$((failures + 1))
fi

ended_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if (( failures == 0 )); then
  result=PASS
else
  result=FAIL
fi
printf 'metadata\tended_utc\t%s\t\t\t\n' "$ended_utc" >> "$summary"
printf 'metadata\tresult\t%s\t\t\t%s\n' "$result" "$((failures > 0))" >> "$summary"
printf 'Evidence summary: %s\n' "$summary"
printf 'Result: %s (%s failed gate(s))\n' "$result" "$failures"
(( failures == 0 ))
