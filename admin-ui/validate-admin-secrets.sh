#!/bin/sh
set -eu

htpasswd_path="/run/secrets/openpay_admin_htpasswd"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

validate_backend_token() {
  if [ "${OPENPAY_ADMIN_BACKEND_TOKEN+x}" != "x" ]; then
    fail "OPENPAY_ADMIN_BACKEND_TOKEN is required."
  fi

  token_length="$(printf '%s' "$OPENPAY_ADMIN_BACKEND_TOKEN" | wc -c | tr -d ' ')"
  if [ "$token_length" -lt 32 ] || [ "$token_length" -gt 2048 ]; then
    fail "OPENPAY_ADMIN_BACKEND_TOKEN length is invalid."
  fi

  case "$OPENPAY_ADMIN_BACKEND_TOKEN" in
    *[!A-Za-z0-9._~+/=-]*)
      fail "OPENPAY_ADMIN_BACKEND_TOKEN contains invalid characters."
      ;;
  esac
}

validate_htpasswd_file() {
  if [ -L "$htpasswd_path" ]; then
    fail "Admin password file must not be a symbolic link."
  fi
  if [ ! -f "$htpasswd_path" ]; then
    fail "Admin password file is required."
  fi
  if [ ! -r "$htpasswd_path" ]; then
    fail "Admin password file is not readable."
  fi

  file_size="$(wc -c < "$htpasswd_path" | tr -d ' ')"
  if [ "$file_size" -lt 1 ] || [ "$file_size" -gt 16384 ]; then
    fail "Admin password file size is invalid."
  fi

  file_mode="$(stat -c '%a' "$htpasswd_path")"
  case "$file_mode" in
    400|440|444|600|640|644)
      ;;
    *)
      fail "Admin password file permissions are unsafe."
      ;;
  esac

  if ! awk '
    BEGIN { valid = 1; count = 0 }
    {
      count += 1
      separator = index($0, ":")
      username = substr($0, 1, separator - 1)
      password_hash = substr($0, separator + 1)
      if (separator <= 1 || length(username) > 128) { valid = 0 }
      if (username !~ /^[A-Za-z0-9._@-]+$/) { valid = 0 }
      if (length(password_hash) < 1 || length(password_hash) > 255) { valid = 0 }
      if (password_hash !~ /^[^[:space:]:]+$/) { valid = 0 }
      if (password_hash !~ /^\$2[aby]\$/ && password_hash !~ /^\$6\$/) { valid = 0 }
      if (seen[username] == 1) { valid = 0 }
      seen[username] = 1
    }
    END {
      if (count < 1 || count > 64 || valid != 1) { exit 1 }
    }
  ' "$htpasswd_path"; then
    fail "Admin password file content is invalid."
  fi
}

validate_backend_token
validate_htpasswd_file
