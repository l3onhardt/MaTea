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

test_json_escape_quotes_and_backslashes() {
  local escaped
  escaped="$(json_escape 'a"b\c')"
  assert_eq 'a\"b\\c' "$escaped" "json_escape escapes quote and backslash"
}

test_valid_port_accepts_range() {
  valid_port "443"
  assert_eq "0" "$?" "valid_port accepts 443"
}

test_valid_port_rejects_bad_values() {
  if valid_port "70000"; then
    assert_eq "reject" "accept" "valid_port rejects 70000"
  else
    assert_eq "reject" "reject" "valid_port rejects 70000"
  fi
}

test_state_round_trip() {
  rm -rf "$FASTVLESS_BASE_DIR"
  mkdir -p "$FASTVLESS_BASE_DIR"
  UUID="11111111-1111-4111-8111-111111111111"
  VLESS_PORT="24443"
  REALITY_SNI="www.example.com"
  save_state
  UUID=""
  VLESS_PORT=""
  REALITY_SNI=""
  load_state
  assert_eq "11111111-1111-4111-8111-111111111111" "$UUID" "state keeps UUID"
  assert_eq "24443" "$VLESS_PORT" "state keeps VLESS port"
  assert_eq "www.example.com" "$REALITY_SNI" "state keeps SNI"
}

test_normalize_arch_maps_common_values() {
  assert_eq "amd64" "$(normalize_arch x86_64)" "x86_64 maps to amd64"
  assert_eq "arm64" "$(normalize_arch aarch64)" "aarch64 maps to arm64"
  assert_eq "armv7" "$(normalize_arch armv7l)" "armv7l maps to armv7"
}

test_normalize_arch_rejects_unknown() {
  if normalize_arch mips >/dev/null 2>&1; then
    assert_eq "reject" "accept" "mips is unsupported"
  else
    assert_eq "reject" "reject" "mips is unsupported"
  fi
}

test_detect_os_family_from_os_release() {
  local fixture="$ROOT_DIR/tests/fixtures/os-release"
  printf 'ID=ubuntu\nID_LIKE=debian\n' >"$fixture"
  assert_eq "debian" "$(detect_os_family "$fixture")" "ubuntu is debian family"
  printf 'ID=rocky\nID_LIKE=\"rhel fedora\"\n' >"$fixture"
  assert_eq "rhel" "$(detect_os_family "$fixture")" "rocky is rhel family"
  printf 'ID=alpine\n' >"$fixture"
  assert_eq "alpine" "$(detect_os_family "$fixture")" "alpine is alpine family"
}

test_can_enable_bbr_blocks_containers() {
  if can_enable_bbr "openvz" "bbr cubic"; then
    assert_eq "block" "allow" "openvz blocks bbr changes"
  else
    assert_eq "block" "block" "openvz blocks bbr changes"
  fi
}

test_can_enable_bbr_allows_kvm_with_bbr() {
  can_enable_bbr "kvm" "bbr cubic"
  assert_eq "0" "$?" "kvm with bbr module can enable bbr"
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
