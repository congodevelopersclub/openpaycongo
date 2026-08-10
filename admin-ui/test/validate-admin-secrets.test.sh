#!/bin/sh
set -eu

validator="/tmp/validate-admin-secrets.sh"
fixture="/tmp/openpay_admin.htpasswd.fixture"
secret_dir="/run/secrets"
secret_path="$secret_dir/openpay_admin_htpasswd"
valid_token="build-validation-token-0000000001"

fail() {
  printf 'validator test failed: %s\n' "$1" >&2
  exit 1
}

remove_secret_path() {
  if [ -d "$secret_path" ]; then
    rmdir "$secret_path"
    return
  fi
  rm -f "$secret_path"
}

install_valid_secret() {
  remove_secret_path
  cp "$fixture" "$secret_path"
  chmod 0444 "$secret_path"
}

expect_failure() {
  test_name="$1"
  if sh "$validator" 2>/dev/null; then
    fail "$test_name"
  fi
}

mkdir -p "$secret_dir"
install_valid_secret
unset OPENPAY_ADMIN_BACKEND_TOKEN
expect_failure "missing backend token"

OPENPAY_ADMIN_BACKEND_TOKEN="short"
export OPENPAY_ADMIN_BACKEND_TOKEN
expect_failure "short backend token"

OPENPAY_ADMIN_BACKEND_TOKEN="$valid_token"
export OPENPAY_ADMIN_BACKEND_TOKEN
sh "$validator"

remove_secret_path
expect_failure "missing password file"

mkdir "$secret_path"
expect_failure "non-regular password path"

install_valid_secret
chmod 0666 "$secret_path"
expect_failure "unsafe password file permissions"

install_valid_secret
: > "$secret_path"
chmod 0444 "$secret_path"
expect_failure "empty password file"

remove_secret_path
dd if=/dev/zero of="$secret_path" bs=16385 count=1 2>/dev/null
chmod 0444 "$secret_path"
expect_failure "oversized password file"

remove_secret_path
printf '%s\n' 'invalid user:{SHA}hash' > "$secret_path"
chmod 0444 "$secret_path"
expect_failure "invalid password file content"

install_valid_secret
sh "$validator"
printf '%s\n' "Admin secret validator contract passed."
