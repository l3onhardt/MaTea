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

test_now_ms_returns_digits() {
  local value
  value="$(now_ms)"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    assert_eq "digits" "digits" "now_ms returns numeric timestamp"
  else
    assert_eq "digits" "$value" "now_ms returns numeric timestamp"
  fi
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

test_trim_input_removes_copy_paste_whitespace() {
  assert_eq "33356" "$(trim_input $' 33356\r')" "trim_input strips whitespace and carriage return"
}

test_state_round_trip() {
  rm -rf "$FASTVLESS_BASE_DIR"
  mkdir -p "$FASTVLESS_BASE_DIR"
  UUID="11111111-1111-4111-8111-111111111111"
  VLESS_PORT="24443"
  REALITY_SNI="www.example.com"
  SERVER_REGION_HINT="asia"
  save_state
  UUID=""
  VLESS_PORT=""
  REALITY_SNI=""
  SERVER_REGION_HINT=""
  load_state
  assert_eq "11111111-1111-4111-8111-111111111111" "$UUID" "state keeps UUID"
  assert_eq "24443" "$VLESS_PORT" "state keeps VLESS port"
  assert_eq "www.example.com" "$REALITY_SNI" "state keeps SNI"
  assert_eq "asia" "$SERVER_REGION_HINT" "state keeps region hint"
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
  LOCAL_SOCKS_LISTEN="::"
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

test_build_socks_links_uses_loopback_for_local_only() {
  SERVER_IP="203.0.113.9"
  LOCAL_SOCKS_LISTEN="127.0.0.1"
  LOCAL_SOCKS_PUBLIC_PORT="24080"
  LOCAL_SOCKS_USER="localuser"
  LOCAL_SOCKS_PASS="localpass"
  local output
  output="$(build_socks_links)"
  if printf '%s\n' "$output" | grep -q 'socks5://localuser:localpass@127.0.0.1:24080'; then
    assert_eq "loopback" "loopback" "local-only socks uses loopback host"
  else
    assert_eq "loopback" "$output" "local-only socks uses loopback host"
  fi
  if printf '%s\n' "$output" | grep -q '203.0.113.9'; then
    assert_eq "no-public-ip" "has-public-ip" "local-only socks should not print public IP"
  else
    assert_eq "no-public-ip" "no-public-ip" "local-only socks should not print public IP"
  fi
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
  grep -q '"listen": "0.0.0.0"' "$FASTVLESS_BASE_DIR/config.json"
  assert_eq "0" "$?" "vless listens on IPv4 wildcard"
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

test_parse_sni_candidate_row_reads_region_domain_penalty() {
  parse_sni_candidate_row "asia|www.example.jp|15"
  assert_eq "asia" "$SNI_ROW_REGION" "sni row region"
  assert_eq "www.example.jp" "$SNI_ROW_DOMAIN" "sni row domain"
  assert_eq "15" "$SNI_ROW_PENALTY" "sni row penalty"
}

test_pick_sni_candidate_rows_prioritizes_region_and_global() {
  local rows picked
  rows=$'asia|asia.example.com|10\neurope|europe.example.com|10\nglobal|global.example.com|20'
  picked="$(pick_sni_candidate_rows "$rows" "asia")"
  printf '%s\n' "$picked" | grep -q 'asia.example.com'
  assert_eq "0" "$?" "regional candidate included"
  printf '%s\n' "$picked" | grep -q 'global.example.com'
  assert_eq "0" "$?" "global candidate included"
  if printf '%s\n' "$picked" | grep -q 'europe.example.com'; then
    assert_eq "excluded" "included" "other region excluded"
  else
    assert_eq "excluded" "excluded" "other region excluded"
  fi
}

test_guess_sni_region_accepts_lowercase_region_hint() {
  assert_eq "asia" "$(guess_sni_region "asia")" "lowercase asia region hint"
  assert_eq "europe" "$(guess_sni_region "europe")" "lowercase europe region hint"
  assert_eq "americas" "$(guess_sni_region "americas")" "lowercase americas region hint"
}

test_guess_sni_region_accepts_country_codes() {
  assert_eq "asia" "$(guess_sni_region "JP")" "JP country code maps to asia"
  assert_eq "europe" "$(guess_sni_region "DE")" "DE country code maps to europe"
  assert_eq "americas" "$(guess_sni_region "US")" "US country code maps to americas"
}

test_extract_country_code_from_geo_response() {
  assert_eq "JP" "$(extract_country_code_from_geo_response $'{\"country\":\"JP\",\"countryCode\":\"JP\"}')" "extracts JSON country code"
  assert_eq "JP" "$(extract_country_code_from_geo_response $'status=success\ncountryCode=JP\nquery=103.197.210.52')" "extracts plain text country code"
}

test_resolve_sni_region_uses_detected_country_before_ip_guess() {
  SERVER_REGION_HINT=""
  SERVER_IP="103.197.210.52"
  FASTVLESS_TEST_GEO_RESPONSE='{"countryCode":"JP"}'
  assert_eq "asia" "$(resolve_sni_region)" "detected JP chooses asia"
}

test_select_best_sni_row_uses_score_not_latency_only() {
  local rows=$'hot.example.com|pass|50|200|ok\nquiet.example.com|pass|120|0|ok\nbad.example.com|fail|10|0|tls13-missing'
  assert_eq "quiet.example.com" "$(select_best_sni_row "$rows")" "SNI scoring penalizes hot candidates"
}

test_sni_output_requires_tls13_x25519_h2_and_cert_match() {
  local output=$'subject=CN = www.example.com\nServer Temp Key: X25519, 253 bits\nNew, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384\nALPN protocol: h2\nVerify return code: 0 (ok)'
  sni_tls_output_passes "$output" "www.example.com"
  assert_eq "0" "$?" "strict SNI output passes"
}

test_sni_output_accepts_subject_cn_spacing() {
  local output=$'subject=CN = www.cloudflare.com\nServer Temp Key: X25519, 253 bits\nNew, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384\nALPN protocol: h2\nVerify return code: 0 (ok)'
  sni_tls_output_passes "$output" "www.cloudflare.com"
  assert_eq "0" "$?" "subject CN with spaces passes"
}

test_sni_output_accepts_openssl_ecdh_x25519_format() {
  local output=$'subject=/CN=www.cloudflare.com\nServer Temp Key: ECDH, X25519, 253 bits\nProtocol  : TLSv1.3\nALPN protocol: h2\nVerify return code: 0 (ok)'
  sni_tls_output_passes "$output" "www.cloudflare.com"
  assert_eq "0" "$?" "OpenSSL ECDH X25519 format passes"
}

test_sni_cert_matches_accepts_subject_with_org_fields() {
  local output=$'subject=C = JP, ST = Tokyo, O = Sony Marketing Inc., CN = www.sony.jp'
  sni_cert_matches "$output" "www.sony.jp"
  assert_eq "0" "$?" "subject with organization fields matches domain"
}

test_sni_cert_matches_accepts_wildcard_parent() {
  local output=$'subject=CN = *.example.com'
  sni_cert_matches "$output" "www.example.com"
  assert_eq "0" "$?" "wildcard parent matches domain"
}

test_sni_output_rejects_missing_h2() {
  local output=$'subject=CN = www.example.com\nServer Temp Key: X25519, 253 bits\nNew, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384\nALPN protocol: http/1.1\nVerify return code: 0 (ok)'
  if sni_tls_output_passes "$output" "www.example.com"; then
    assert_eq "reject" "accept" "missing h2 rejected"
  else
    assert_eq "reject" "reject" "missing h2 rejected"
  fi
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
  LOCAL_SOCKS_ENABLED=""
  LOCAL_SOCKS_LISTEN=""
  VLESS_PORT=""
  LOCAL_SOCKS_PORT=""
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

test_select_port_accepts_pasted_port_with_carriage_return() {
  local selected
  selected="$(printf '33356\r\n' | select_port "VLESS" "23333")"
  assert_eq "33356" "$selected" "select_port accepts pasted CRLF port"
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

test_prompt_yes_no_retries_invalid_then_accepts_yes() {
  if printf '33356\ny\n' | prompt_yes_no "NAT?" "n"; then
    assert_eq "yes" "yes" "prompt_yes_no retries invalid input then accepts y"
  else
    assert_eq "yes" "no" "prompt_yes_no retries invalid input then accepts y"
  fi
}

test_disable_local_socks_clears_old_state() {
  LOCAL_SOCKS_ENABLED="1"
  LOCAL_SOCKS_LISTEN="::"
  LOCAL_SOCKS_PORT="33357"
  LOCAL_SOCKS_PUBLIC_PORT="33357"
  LOCAL_SOCKS_USER="olduser"
  LOCAL_SOCKS_PASS="oldpass"
  disable_local_socks
  assert_eq "0" "$LOCAL_SOCKS_ENABLED" "local socks disabled"
  assert_eq "" "$LOCAL_SOCKS_PORT" "local socks port cleared"
  assert_eq "" "$LOCAL_SOCKS_USER" "local socks user cleared"
}

test_enable_local_socks_default_generates_complete_state() {
  LOCAL_SOCKS_ENABLED="0"
  LOCAL_SOCKS_LISTEN=""
  LOCAL_SOCKS_PORT=""
  LOCAL_SOCKS_PUBLIC_PORT=""
  LOCAL_SOCKS_USER=""
  LOCAL_SOCKS_PASS=""
  enable_local_socks_default
  assert_eq "1" "$LOCAL_SOCKS_ENABLED" "local socks enabled"
  assert_eq "127.0.0.1" "$LOCAL_SOCKS_LISTEN" "local socks default listen is local"
  if valid_port "$LOCAL_SOCKS_PORT"; then
    assert_eq "valid" "valid" "local socks default port generated"
  else
    assert_eq "valid" "$LOCAL_SOCKS_PORT" "local socks default port generated"
  fi
  assert_eq "$LOCAL_SOCKS_PORT" "$LOCAL_SOCKS_PUBLIC_PORT" "local socks public port defaults to listen port"
  [[ -n "$LOCAL_SOCKS_USER" && -n "$LOCAL_SOCKS_PASS" ]]
  assert_eq "0" "$?" "local socks credentials generated"
}

test_listen_output_detects_exact_port() {
  local output
  output=$'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\nLISTEN 0 4096 0.0.0.0:33356 0.0.0.0:* users:(("sing-box",pid=1,fd=3))'
  ss_listen_output_has_port "$output" "33356"
  assert_eq "0" "$?" "listen parser detects expected port"
  if ss_listen_output_has_port "$output" "3335"; then
    assert_eq "reject" "accept" "listen parser does not match partial port"
  else
    assert_eq "reject" "reject" "listen parser does not match partial port"
  fi
}

test_show_links_rebuilds_when_socks_disabled() {
  rm -rf "$FASTVLESS_BASE_DIR"
  mkdir -p "$FASTVLESS_BASE_DIR"
  UUID="11111111-1111-4111-8111-111111111111"
  SERVER_IP="203.0.113.9"
  VLESS_PORT="24443"
  PUBLIC_VLESS_PORT="24443"
  REALITY_SNI="www.example.com"
  REALITY_PUBLIC_KEY="publicKeyValue"
  REALITY_SHORT_ID="abcd1234"
  LOCAL_SOCKS_ENABLED="0"
  save_state
  printf 'VLESS Reality:\nstale\n\nSOCKS5 标准格式: socks5://old:old@203.0.113.9:33357\n' >"$FASTVLESS_BASE_DIR/links.txt"
  local output
  output="$(show_links)"
  if printf '%s\n' "$output" | grep -q 'SOCKS5'; then
    assert_eq "no-socks" "$output" "show_links does not show stale socks links"
  else
    assert_eq "no-socks" "no-socks" "show_links does not show stale socks links"
  fi
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
