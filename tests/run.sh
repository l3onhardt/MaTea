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

test_banner_contains_mawang_brand() {
  local output
  output="$(print_banner)"
  printf '%s\n' "$output" | grep -q '马王脚本'
  assert_eq "0" "$?" "banner shows Ma Wang brand"
  printf '%s\n' "$output" | grep -q '马哥梯子'
  assert_eq "0" "$?" "banner shows Ma Ge ladder tagline"
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

test_parse_socks_legacy_format() {
  parse_socks_uri 'socks5://82.153.200.96:45001:dVO69eb58eac45a6:k8oRVgpuiE29MKCTOd'
  assert_eq "82.153.200.96" "$SOCKS_HOST" "legacy socks host"
  assert_eq "45001" "$SOCKS_PORT" "legacy socks port"
  assert_eq "dVO69eb58eac45a6" "$SOCKS_USER" "legacy socks user"
  assert_eq "k8oRVgpuiE29MKCTOd" "$SOCKS_PASS" "legacy socks password"
}

test_parse_socks_standard_uri() {
  parse_socks_uri 'socks5://user123:pass456@proxy.example.com:1080'
  assert_eq "proxy.example.com" "$SOCKS_HOST" "standard socks host"
  assert_eq "1080" "$SOCKS_PORT" "standard socks port"
  assert_eq "user123" "$SOCKS_USER" "standard socks user"
  assert_eq "pass456" "$SOCKS_PASS" "standard socks password"
}

test_parse_socks_rejects_bad_port() {
  if parse_socks_uri 'socks5://host:99999:user:pass'; then
    assert_eq "reject" "accept" "socks rejects bad port"
  else
    assert_eq "reject" "reject" "socks rejects bad port"
  fi
}

test_build_socks_links_outputs_two_formats() {
  SERVER_IP="203.0.113.9"
  LOCAL_SOCKS_PUBLIC_PORT="24080"
  LOCAL_SOCKS_USER="localuser"
  LOCAL_SOCKS_PASS="localpass"
  local output
  output="$(build_socks_links)"
  printf '%s\n' "$output" | grep -q 'socks5://localuser:localpass@203.0.113.9:24080'
  assert_eq "0" "$?" "socks auth URI is printed"
  printf '%s\n' "$output" | grep -q 'socks5://203.0.113.9:24080:localuser:localpass'
  assert_eq "0" "$?" "socks compatibility URI is printed"
}

test_build_vless_link_contains_reality_parameters() {
  UUID="11111111-1111-4111-8111-111111111111"
  SERVER_IP="203.0.113.9"
  PUBLIC_VLESS_PORT="24443"
  REALITY_SNI="www.example.com"
  REALITY_PUBLIC_KEY="publicKeyValue"
  REALITY_SHORT_ID="abcd1234"
  local link
  link="$(build_vless_link)"
  printf '%s\n' "$link" | grep -q '^vless://11111111-1111-4111-8111-111111111111@203.0.113.9:24443?'
  assert_eq "0" "$?" "vless link starts with uuid host port"
  printf '%s\n' "$link" | grep -q 'security=reality'
  assert_eq "0" "$?" "vless link has reality security"
  printf '%s\n' "$link" | grep -q 'sni=www.example.com'
  assert_eq "0" "$?" "vless link has sni"
  printf '%s\n' "$link" | grep -q 'pbk=publicKeyValue'
  assert_eq "0" "$?" "vless link has public key"
  printf '%s\n' "$link" | grep -q 'sid=abcd1234'
  assert_eq "0" "$?" "vless link has short id"
}

test_write_config_with_direct_outbound() {
  rm -rf "$FASTVLESS_BASE_DIR"
  mkdir -p "$FASTVLESS_BASE_DIR"
  UUID="11111111-1111-4111-8111-111111111111"
  VLESS_PORT="24443"
  REALITY_SNI="www.example.com"
  REALITY_PRIVATE_KEY="privateKeyValue"
  REALITY_SHORT_ID="abcd1234"
  UPSTREAM_SOCKS_ENABLED="0"
  LOCAL_SOCKS_ENABLED="0"
  write_config "$FASTVLESS_BASE_DIR/config.json"
  grep -q '"type": "vless"' "$FASTVLESS_BASE_DIR/config.json"
  assert_eq "0" "$?" "config contains vless inbound"
  grep -q '"tag": "direct"' "$FASTVLESS_BASE_DIR/config.json"
  assert_eq "0" "$?" "config contains direct outbound"
}

test_write_config_with_upstream_and_local_socks() {
  rm -rf "$FASTVLESS_BASE_DIR"
  mkdir -p "$FASTVLESS_BASE_DIR"
  UUID="11111111-1111-4111-8111-111111111111"
  VLESS_PORT="24443"
  REALITY_SNI="www.example.com"
  REALITY_PRIVATE_KEY="privateKeyValue"
  REALITY_SHORT_ID="abcd1234"
  UPSTREAM_SOCKS_ENABLED="1"
  UPSTREAM_SOCKS_HOST="proxy.example.com"
  UPSTREAM_SOCKS_PORT="1080"
  UPSTREAM_SOCKS_USER="upuser"
  UPSTREAM_SOCKS_PASS="uppass"
  LOCAL_SOCKS_ENABLED="1"
  LOCAL_SOCKS_LISTEN="127.0.0.1"
  LOCAL_SOCKS_PORT="24080"
  LOCAL_SOCKS_USER="localuser"
  LOCAL_SOCKS_PASS="localpass"
  write_config "$FASTVLESS_BASE_DIR/config.json"
  grep -q '"tag": "upstream-socks"' "$FASTVLESS_BASE_DIR/config.json"
  assert_eq "0" "$?" "config contains upstream socks outbound"
  grep -q '"tag": "local-socks"' "$FASTVLESS_BASE_DIR/config.json"
  assert_eq "0" "$?" "config contains local socks inbound"
}

test_sing_box_asset_name_for_amd64() {
  assert_eq "sing-box-1.13.11-linux-amd64.tar.gz" "$(sing_box_asset_name 1.13.11 amd64)" "amd64 asset name"
}

test_sing_box_asset_name_for_arm64() {
  assert_eq "sing-box-1.13.11-linux-arm64.tar.gz" "$(sing_box_asset_name 1.13.11 arm64)" "arm64 asset name"
}

test_parse_reality_keypair_output() {
  parse_reality_keypair_output $'PrivateKey: private-value\nPublicKey: public-value\n'
  assert_eq "private-value" "$REALITY_PRIVATE_KEY" "parsed private key"
  assert_eq "public-value" "$REALITY_PUBLIC_KEY" "parsed public key"
}

test_validate_sni_domain_accepts_hostname() {
  validate_sni_domain "www.example.com"
  assert_eq "0" "$?" "valid hostname accepted"
}

test_validate_sni_domain_rejects_protocol() {
  if validate_sni_domain "https://www.example.com"; then
    assert_eq "reject" "accept" "protocol rejected"
  else
    assert_eq "reject" "reject" "protocol rejected"
  fi
}

test_select_best_sni_row_picks_lowest_latency_pass() {
  local rows=$'www.slow.com|pass|300\nwww.fast.com|pass|80\nwww.fail.com|fail|20'
  assert_eq "www.fast.com" "$(select_best_sni_row "$rows")" "lowest latency passing SNI selected"
}

test_write_bbr_sysctl_file() {
  rm -rf "$FASTVLESS_SYSCTL_DIR"
  mkdir -p "$FASTVLESS_SYSCTL_DIR"
  write_bbr_sysctl_file
  grep -q 'net.core.default_qdisc=fq' "$FASTVLESS_SYSCTL_DIR/99-fastvless-bbr.conf"
  assert_eq "0" "$?" "bbr sysctl has fq"
  grep -q 'net.ipv4.tcp_congestion_control=bbr' "$FASTVLESS_SYSCTL_DIR/99-fastvless-bbr.conf"
  assert_eq "0" "$?" "bbr sysctl has bbr"
}

test_write_systemd_service_file() {
  rm -rf "$FASTVLESS_SYSTEMD_DIR"
  mkdir -p "$FASTVLESS_SYSTEMD_DIR" "$FASTVLESS_BASE_DIR"
  write_systemd_service
  grep -q 'ExecStart=.*sing-box run -c' "$FASTVLESS_SYSTEMD_DIR/fastvless.service"
  assert_eq "0" "$?" "systemd service runs sing-box"
}

test_menu_contains_core_actions() {
  local menu
  menu="$(menu_text)"
  printf '%s\n' "$menu" | grep -q '推荐一键安装'
  assert_eq "0" "$?" "menu has recommended install"
  printf '%s\n' "$menu" | grep -q '配置上游 SOCKS5'
  assert_eq "0" "$?" "menu has upstream socks action"
  printf '%s\n' "$menu" | grep -q '开启/关闭本机 SOCKS5'
  assert_eq "0" "$?" "menu has local socks action"
}

test_initialize_defaults_sets_safe_local_socks() {
  initialize_defaults
  assert_eq "0" "$LOCAL_SOCKS_ENABLED" "local socks disabled by default"
  assert_eq "127.0.0.1" "$LOCAL_SOCKS_LISTEN" "local socks listens locally by default"
  assert_eq "" "$VLESS_PORT" "vless port is chosen during install"
  assert_eq "" "$LOCAL_SOCKS_PORT" "local socks port is chosen only when enabled"
}

test_select_port_uses_user_value() {
  local selected
  selected="$(printf '24443\n' | select_port "VLESS" "23333")"
  assert_eq "24443" "$selected" "select_port accepts user port"
}

test_select_port_uses_default_on_empty() {
  local selected
  selected="$(printf '\n' | select_port "VLESS" "23333")"
  assert_eq "23333" "$selected" "select_port uses default on empty input"
}

test_select_port_retries_invalid_value() {
  local selected
  selected="$(printf '70000\n24443\n' | select_port "VLESS" "23333")"
  assert_eq "24443" "$selected" "select_port retries invalid input"
}

test_select_port_can_override_existing_port_default() {
  local selected
  VLESS_PORT="30000"
  selected="$(printf '443\n' | select_port "VLESS" "$VLESS_PORT")"
  assert_eq "443" "$selected" "select_port overrides existing port when user enters one"
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
