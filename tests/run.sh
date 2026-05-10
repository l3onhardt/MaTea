#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FASTVLESS_TEST_MODE=1
export FASTVLESS_BASE_DIR="$ROOT_DIR/tests/fixtures/etc/fastvless"
export FASTVLESS_SYSTEMD_DIR="$ROOT_DIR/tests/fixtures/systemd"
export FASTVLESS_SYSCTL_DIR="$ROOT_DIR/tests/fixtures/sysctl.d"

source "$ROOT_DIR/fastvless.sh"

pass_count=0
fail_count=0

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [[ "$expected" != "$actual" ]]; then
    printf 'not ok - %s\n  expected: %s\n  actual:   %s\n' "$label" "$expected" "$actual"
    fail_count=$((fail_count + 1))
    return 1
  fi
  printf 'ok - %s\n' "$label"
  pass_count=$((pass_count + 1))
}

test_script_exposes_app_name() {
  assert_eq "fastvless" "$APP_NAME" "APP_NAME is fastvless"
}

main() {
  rm -rf "$ROOT_DIR/tests/fixtures/etc" "$ROOT_DIR/tests/fixtures/systemd" "$ROOT_DIR/tests/fixtures/sysctl.d"
  mkdir -p "$ROOT_DIR/tests/fixtures"

  local test_name
  while IFS= read -r test_name; do
    "$test_name"
  done < <(declare -F | awk '{print $3}' | grep '^test_' | sort)

  printf '\n%s passed, %s failed\n' "$pass_count" "$fail_count"
  [[ "$fail_count" -eq 0 ]]
}

main "$@"
