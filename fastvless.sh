#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="fastvless"
DISPLAY_NAME="马王脚本"
DISPLAY_TAGLINE="马哥梯子 | VLESS Reality 一键加速"
BASE_DIR="${FASTVLESS_BASE_DIR:-/etc/fastvless}"
SYSTEMD_DIR="${FASTVLESS_SYSTEMD_DIR:-/etc/systemd/system}"
SYSCTL_DIR="${FASTVLESS_SYSCTL_DIR:-/etc/sysctl.d}"
SERVICE_NAME="fastvless"
SCRIPT_FILE="$BASE_DIR/fastvless.sh"
SING_BOX_BIN="$BASE_DIR/sing-box"
CONFIG_FILE="$BASE_DIR/config.json"
STATE_FILE="$BASE_DIR/state.env"
LINKS_FILE="$BASE_DIR/links.txt"
LOG_FILE="$BASE_DIR/install.log"
PID_FILE="$BASE_DIR/fastvless.pid"
BBR_SYSCTL_FILE="$SYSCTL_DIR/99-fastvless-bbr.conf"
SING_BOX_VERSION_DEFAULT="1.13.11"

log_line() {
  local level="$1"
  shift
  mkdir -p "$BASE_DIR" 2>/dev/null || true
  if [[ -d "$BASE_DIR" ]]; then
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >>"$LOG_FILE" 2>/dev/null || true
  fi
}

info() {
  printf '[+] %s\n' "$*"
  log_line "INFO" "$*"
}

warn() {
  printf '[!] %s\n' "$*"
  log_line "WARN" "$*"
}

die() {
  printf '[x] %s\n' "$*" >&2
  log_line "ERROR" "$*"
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

now_ms() {
  local value
  value="$(date +%s%3N 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s000\n' "$(date +%s)"
  fi
}

banner_text() {
  cat <<'EOF_BANNER'
 __  __    _    __        ___    _   _  ____
|  \/  |  / \   \ \      / / \  | \ | |/ ___|
| |\/| | / _ \   \ \ /\ / / _ \ |  \| | |  _
| |  | |/ ___ \   \ V  V / ___ \| |\  | |_| |
|_|  |_/_/   \_\   \_/\_/_/   \_\_| \_|\____|
EOF_BANNER
}

print_banner() {
  banner_text
  printf '%s\n' "$DISPLAY_NAME"
  printf '%s\n' "$DISPLAY_TAGLINE"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

trim_input() {
  printf '%s' "${1:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

valid_port() {
  local port
  port="$(trim_input "${1:-}")"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 ))
}

random_hex() {
  local bytes="${1:-8}"
  if command_exists openssl; then
    openssl rand -hex "$bytes"
    return
  fi
  od -An -N"$bytes" -tx1 /dev/urandom | tr -d ' \n'
}

random_password() {
  random_hex 12
}

save_state() {
  mkdir -p "$BASE_DIR"
  umask 077
  {
    printf 'UUID=%q\n' "${UUID:-}"
    printf 'VLESS_PORT=%q\n' "${VLESS_PORT:-}"
    printf 'PUBLIC_VLESS_PORT=%q\n' "${PUBLIC_VLESS_PORT:-${VLESS_PORT:-}}"
    printf 'REALITY_SNI=%q\n' "${REALITY_SNI:-}"
    printf 'REALITY_PRIVATE_KEY=%q\n' "${REALITY_PRIVATE_KEY:-}"
    printf 'REALITY_PUBLIC_KEY=%q\n' "${REALITY_PUBLIC_KEY:-}"
    printf 'REALITY_SHORT_ID=%q\n' "${REALITY_SHORT_ID:-}"
    printf 'SERVER_IP=%q\n' "${SERVER_IP:-}"
    printf 'SERVER_REGION_HINT=%q\n' "${SERVER_REGION_HINT:-}"
    printf 'UPSTREAM_SOCKS_ENABLED=%q\n' "${UPSTREAM_SOCKS_ENABLED:-0}"
    printf 'UPSTREAM_SOCKS_HOST=%q\n' "${UPSTREAM_SOCKS_HOST:-}"
    printf 'UPSTREAM_SOCKS_PORT=%q\n' "${UPSTREAM_SOCKS_PORT:-}"
    printf 'UPSTREAM_SOCKS_USER=%q\n' "${UPSTREAM_SOCKS_USER:-}"
    printf 'UPSTREAM_SOCKS_PASS=%q\n' "${UPSTREAM_SOCKS_PASS:-}"
    printf 'LOCAL_SOCKS_ENABLED=%q\n' "${LOCAL_SOCKS_ENABLED:-0}"
    printf 'LOCAL_SOCKS_LISTEN=%q\n' "${LOCAL_SOCKS_LISTEN:-127.0.0.1}"
    printf 'LOCAL_SOCKS_PORT=%q\n' "${LOCAL_SOCKS_PORT:-}"
    printf 'LOCAL_SOCKS_PUBLIC_PORT=%q\n' "${LOCAL_SOCKS_PUBLIC_PORT:-${LOCAL_SOCKS_PORT:-}}"
    printf 'LOCAL_SOCKS_USER=%q\n' "${LOCAL_SOCKS_USER:-}"
    printf 'LOCAL_SOCKS_PASS=%q\n' "${LOCAL_SOCKS_PASS:-}"
  } >"$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || return 0
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

normalize_arch() {
  case "${1:-$(uname -m)}" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    armv7l|armv7) printf 'armv7\n' ;;
    *) return 1 ;;
  esac
}

detect_os_family() {
  local os_release="${1:-/etc/os-release}"
  local data id like
  data="$(cat "$os_release" 2>/dev/null || true)"
  id="$(printf '%s\n' "$data" | awk -F= '$1=="ID"{gsub(/"/,"",$2); print $2; exit}')"
  like="$(printf '%s\n' "$data" | awk -F= '$1=="ID_LIKE"{gsub(/"/,"",$2); print $2; exit}')"
  case " $id $like " in
    *" debian "*|*" ubuntu "*) printf 'debian\n' ;;
    *" rhel "*|*" centos "*|*" fedora "*|*" rocky "*|*" almalinux "*) printf 'rhel\n' ;;
    *" alpine "*) printf 'alpine\n' ;;
    *) printf 'unsupported\n' ;;
  esac
}

detect_init_system() {
  if command_exists systemctl && [[ -d /run/systemd/system || -d /etc/systemd/system ]]; then
    printf 'systemd\n'
  elif command_exists rc-service; then
    printf 'openrc\n'
  else
    printf 'none\n'
  fi
}

detect_virtualization() {
  if command_exists systemd-detect-virt; then
    systemd-detect-virt 2>/dev/null && return 0
  fi
  if [[ -f /proc/user_beancounters ]]; then
    printf 'openvz\n'
  elif grep -qaE 'docker|lxc|kubepods|containerd' /proc/1/cgroup 2>/dev/null; then
    printf 'container\n'
  elif grep -qaE 'KVM|QEMU' /proc/cpuinfo 2>/dev/null; then
    printf 'kvm\n'
  else
    printf 'unknown\n'
  fi
}

get_available_bbr_modules() {
  sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | awk -F= '{gsub(/^ /,"",$2); print $2}'
}

get_current_bbr() {
  sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk -F= '{gsub(/^ /,"",$2); print $2}'
}

can_enable_bbr() {
  local virt="$1"
  local available="$2"
  case "$virt" in
    openvz|lxc|container|docker) return 1 ;;
  esac
  printf '%s\n' "$available" | grep -qw bbr
}

free_space_mb() {
  local path="${1:-/etc}"
  df -Pm "$path" 2>/dev/null | awk 'NR==2 {print $4}'
}

preflight_space_check() {
  local etc_mb tmp_mb
  etc_mb="$(free_space_mb /etc)"
  tmp_mb="$(free_space_mb /tmp)"
  [[ -n "$etc_mb" && "$etc_mb" -ge 150 ]] || die "/etc 可用空间不足 150MB"
  [[ -n "$tmp_mb" && "$tmp_mb" -ge 150 ]] || die "/tmp 可用空间不足 150MB"
}

parse_socks_uri() {
  local input="${1:-}"
  local body auth hostport parts_count
  SOCKS_HOST=""
  SOCKS_PORT=""
  SOCKS_USER=""
  SOCKS_PASS=""

  [[ "$input" == socks5://* ]] || return 1
  body="${input#socks5://}"
  [[ -n "$body" ]] || return 1

  if [[ "$body" == *@* ]]; then
    auth="${body%@*}"
    hostport="${body#*@}"
    [[ "$auth" == *:* && "$hostport" == *:* ]] || return 1
    SOCKS_USER="${auth%%:*}"
    SOCKS_PASS="${auth#*:}"
    SOCKS_HOST="${hostport%:*}"
    SOCKS_PORT="${hostport##*:}"
  else
    parts_count="$(awk -F: '{print NF}' <<<"$body")"
    [[ "$parts_count" -eq 4 ]] || return 1
    SOCKS_HOST="$(awk -F: '{print $1}' <<<"$body")"
    SOCKS_PORT="$(awk -F: '{print $2}' <<<"$body")"
    SOCKS_USER="$(awk -F: '{print $3}' <<<"$body")"
    SOCKS_PASS="$(awk -F: '{print $4}' <<<"$body")"
  fi

  [[ -n "$SOCKS_HOST" && -n "$SOCKS_USER" && -n "$SOCKS_PASS" ]] || return 1
  valid_port "$SOCKS_PORT"
}

build_socks_links() {
  local ip="${SERVER_IP:-}"
  local port="${LOCAL_SOCKS_PUBLIC_PORT:-${LOCAL_SOCKS_PORT:-}}"
  local user="${LOCAL_SOCKS_USER:-}"
  local pass="${LOCAL_SOCKS_PASS:-}"
  if [[ "${LOCAL_SOCKS_LISTEN:-127.0.0.1}" == "127.0.0.1" ]]; then
    ip="127.0.0.1"
  fi
  [[ -n "$ip" && -n "$port" && -n "$user" && -n "$pass" ]] || return 1
  printf 'SOCKS5 标准格式: socks5://%s:%s@%s:%s\n' "$user" "$pass" "$ip" "$port"
  printf 'SOCKS5 兼容格式: socks5://%s:%s:%s:%s\n' "$ip" "$port" "$user" "$pass"
}

configure_upstream_socks_from_uri() {
  local input="$1"
  parse_socks_uri "$input" || return 1
  UPSTREAM_SOCKS_ENABLED="1"
  UPSTREAM_SOCKS_HOST="$SOCKS_HOST"
  UPSTREAM_SOCKS_PORT="$SOCKS_PORT"
  UPSTREAM_SOCKS_USER="$SOCKS_USER"
  UPSTREAM_SOCKS_PASS="$SOCKS_PASS"
  save_state
}

build_vless_link() {
  local uuid="${UUID:-}"
  local ip="${SERVER_IP:-}"
  local port="${PUBLIC_VLESS_PORT:-${VLESS_PORT:-}}"
  local sni="${REALITY_SNI:-}"
  local public_key="${REALITY_PUBLIC_KEY:-}"
  local short_id="${REALITY_SHORT_ID:-}"
  [[ -n "$uuid" && -n "$ip" && -n "$port" && -n "$sni" && -n "$public_key" && -n "$short_id" ]] || return 1
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#fastvless-%s\n' \
    "$uuid" "$ip" "$port" "$sni" "$public_key" "$short_id" "$sni"
}

write_config() {
  local output="${1:-$CONFIG_FILE}"
  local final_outbound="direct"
  local local_socks_block=""
  local upstream_socks_block=""

  if [[ "${UPSTREAM_SOCKS_ENABLED:-0}" == "1" ]]; then
    final_outbound="upstream-socks"
    upstream_socks_block=",{
      \"type\": \"socks\",
      \"tag\": \"upstream-socks\",
      \"server\": \"$(json_escape "$UPSTREAM_SOCKS_HOST")\",
      \"server_port\": ${UPSTREAM_SOCKS_PORT},
      \"version\": \"5\",
      \"username\": \"$(json_escape "$UPSTREAM_SOCKS_USER")\",
      \"password\": \"$(json_escape "$UPSTREAM_SOCKS_PASS")\"
    }"
  fi

  if [[ "${LOCAL_SOCKS_ENABLED:-0}" == "1" ]]; then
    local_socks_block=",{
      \"type\": \"socks\",
      \"tag\": \"local-socks\",
      \"listen\": \"$(json_escape "$LOCAL_SOCKS_LISTEN")\",
      \"listen_port\": ${LOCAL_SOCKS_PORT},
      \"users\": [
        {
          \"username\": \"$(json_escape "$LOCAL_SOCKS_USER")\",
          \"password\": \"$(json_escape "$LOCAL_SOCKS_PASS")\"
        }
      ]
    }"
  fi

  mkdir -p "$(dirname "$output")"
  umask 077
  cat >"$output.tmp" <<EOF_CONFIG
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "listen_port": ${VLESS_PORT},
      "users": [
        {
          "uuid": "$(json_escape "$UUID")",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$(json_escape "$REALITY_SNI")",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$(json_escape "$REALITY_SNI")",
            "server_port": 443
          },
          "private_key": "$(json_escape "$REALITY_PRIVATE_KEY")",
          "short_id": [
            "$(json_escape "$REALITY_SHORT_ID")"
          ]
        }
      }
    }${local_socks_block}
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }${upstream_socks_block}
  ],
  "route": {
    "final": "${final_outbound}"
  }
}
EOF_CONFIG
  mv "$output.tmp" "$output"
  chmod 600 "$output"
}

write_links() {
  mkdir -p "$BASE_DIR"
  {
    printf 'VLESS Reality:\n'
    build_vless_link
    if [[ "${LOCAL_SOCKS_ENABLED:-0}" == "1" ]]; then
      printf '\n'
      build_socks_links
    fi
  } >"$LINKS_FILE"
  chmod 600 "$LINKS_FILE"
}

sing_box_asset_name() {
  local version="$1"
  local arch="$2"
  case "$arch" in
    amd64|arm64|armv7) ;;
    *) return 1 ;;
  esac
  printf 'sing-box-%s-linux-%s.tar.gz\n' "$version" "$arch"
}

download_file() {
  local url="$1"
  local output="$2"
  if command_exists curl; then
    curl -fL --retry 2 --connect-timeout 10 -o "$output" "$url"
  elif command_exists wget; then
    wget -O "$output" "$url"
  else
    return 1
  fi
}

install_sing_box_binary() {
  local version="${1:-$SING_BOX_VERSION_DEFAULT}"
  local arch asset url tmp_dir archive extracted
  arch="$(normalize_arch)"
  asset="$(sing_box_asset_name "$version" "$arch")"
  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${asset}"
  tmp_dir="$(mktemp -d)"
  archive="$tmp_dir/$asset"
  mkdir -p "$BASE_DIR"
  info "下载 sing-box $version ($arch)"
  download_file "$url" "$archive" || die "sing-box 下载失败: $url"
  tar -xzf "$archive" -C "$tmp_dir" || die "sing-box 解压失败"
  extracted="$(find "$tmp_dir" -type f -name sing-box | head -n 1)"
  [[ -n "$extracted" ]] || die "sing-box 压缩包中没有找到二进制文件"
  install -m 755 "$extracted" "$SING_BOX_BIN"
  rm -rf "$tmp_dir"
}

parse_reality_keypair_output() {
  local output="$1"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "$output" | awk -F: '/PrivateKey/{gsub(/^ /,"",$2); print $2; exit}')"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "$output" | awk -F: '/PublicKey/{gsub(/^ /,"",$2); print $2; exit}')"
  [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]]
}

generate_reality_values() {
  [[ -x "$SING_BOX_BIN" ]] || die "sing-box 不存在，无法生成 Reality 密钥"
  local output
  output="$("$SING_BOX_BIN" generate reality-keypair)"
  parse_reality_keypair_output "$output" || die "Reality 密钥生成失败"
  REALITY_SHORT_ID="$("$SING_BOX_BIN" generate rand --hex 4)"
}

validate_config_if_possible() {
  local config_path="${1:-$CONFIG_FILE}"
  if [[ -x "$SING_BOX_BIN" ]]; then
    "$SING_BOX_BIN" check -c "$config_path"
  fi
}

default_sni_candidates() {
  cat <<'EOF_SNI'
jp|www.sony.jp|3
jp|www.nintendo.co.jp|3
jp|www.panasonic.com|5
jp|www.jal.co.jp|5
jp|www.ana.co.jp|5
jp|www.kddi.com|8
jp|www.ntt.com|8
jp|www.softbank.jp|12
asia|www.asus.com|8
asia|www.acer.com|8
asia|www.tsmc.com|8
asia|www.cathaypacific.com|8
asia|www.singaporeair.com|8
asia|www.samsung.com|25
asia|www.cloudflare.com|180
asia|www.microsoft.com|180
americas|www.ibm.com|8
americas|www.cisco.com|8
americas|www.oracle.com|8
americas|www.intel.com|8
americas|www.amd.com|8
americas|www.dell.com|12
americas|www.hp.com|12
americas|www.mozilla.org|20
americas|www.apple.com|160
americas|www.microsoft.com|180
americas|www.cloudflare.com|180
europe|www.sap.com|8
europe|www.siemens.com|8
europe|www.bosch.com|8
europe|www.ericsson.com|10
europe|www.nokia.com|10
europe|www.volvocars.com|12
europe|www.vodafone.com|15
europe|www.bt.com|15
europe|www.bbc.com|30
europe|www.microsoft.com|180
global|www.wikimedia.org|20
global|www.debian.org|20
global|www.ubuntu.com|25
global|www.mozilla.org|30
global|www.bing.com|120
global|www.apple.com|160
global|www.cloudflare.com|180
global|www.microsoft.com|180
EOF_SNI
}

guess_sni_region() {
  local text="${1:-${SERVER_IP:-}}"
  text="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  case "$text" in
    japan|jp|tokyo|osaka) printf 'jp\n' ;;
    korea|kr|seoul|singapore|sg|hong*|hk|taiwan|tw|asia) printf 'asia\n' ;;
    germany|de|france|fr|netherlands|nl|united*kingdom|gb|uk|london|europe) printf 'europe\n' ;;
    united*states|us|america|canada|ca|americas) printf 'americas\n' ;;
    *) printf 'global\n' ;;
  esac
}

extract_country_code_from_geo_response() {
  local response="$1"
  local code
  code="$(printf '%s\n' "$response" |
    awk -F'["=:, ]+' '
      BEGIN { IGNORECASE=1 }
      {
        for (i = 1; i <= NF; i++) {
          if (($i == "countryCode" || $i == "country_code" || $i == "country") && (i + 1) <= NF) {
            print $(i + 1)
            exit
          }
        }
      }
    ' |
    tr -dc 'A-Za-z' |
    tr '[:lower:]' '[:upper:]' |
    head -c 2)"
  [[ "$code" =~ ^[A-Z][A-Z]$ ]] && printf '%s\n' "$code"
}

detect_server_country_code() {
  local ip="${1:-${SERVER_IP:-}}"
  local url response code
  if [[ -n "${FASTVLESS_TEST_GEO_RESPONSE:-}" ]]; then
    extract_country_code_from_geo_response "$FASTVLESS_TEST_GEO_RESPONSE"
    return
  fi
  [[ -n "$ip" ]] || return 1
  for url in \
    "http://ip-api.com/line/${ip}?fields=countryCode" \
    "https://ipapi.co/${ip}/country/" \
    "https://ipinfo.io/${ip}/country"; do
    if command_exists curl; then
      response="$(curl -fsS --max-time 4 "$url" 2>/dev/null || true)"
    elif command_exists wget; then
      response="$(wget -qO- --timeout=4 "$url" 2>/dev/null || true)"
    else
      return 1
    fi
    code="$(extract_country_code_from_geo_response "$response")"
    if [[ -z "$code" ]]; then
      code="$(printf '%s' "$response" | tr -dc 'A-Za-z' | tr '[:lower:]' '[:upper:]' | head -c 2)"
    fi
    if [[ "$code" =~ ^[A-Z][A-Z]$ ]]; then
      printf '%s\n' "$code"
      return 0
    fi
  done
  return 1
}

resolve_sni_region() {
  local country region
  RESOLVED_SNI_REGION=""
  if [[ -n "${SERVER_REGION_HINT:-}" ]]; then
    region="$(guess_sni_region "$SERVER_REGION_HINT")"
    [[ "$region" != "global" ]] && {
      RESOLVED_SNI_REGION="$region"
      printf '%s\n' "$region"
      return 0
    }
  fi
  country="$(detect_server_country_code "${SERVER_IP:-}" || true)"
  if [[ -n "$country" ]]; then
    SERVER_REGION_HINT="$country"
    region="$(guess_sni_region "$country")"
    [[ "$region" != "global" ]] && {
      RESOLVED_SNI_REGION="$region"
      printf '%s\n' "$region"
      return 0
    }
  fi
  RESOLVED_SNI_REGION="$(guess_sni_region "${SERVER_REGION_HINT:-${SERVER_IP:-}}")"
  printf '%s\n' "$RESOLVED_SNI_REGION"
}

refresh_sni_region() {
  local country region
  RESOLVED_SNI_REGION=""
  country="$(detect_server_country_code "${SERVER_IP:-}" || true)"
  if [[ -n "$country" ]]; then
    SERVER_REGION_HINT="$country"
    region="$(guess_sni_region "$country")"
    RESOLVED_SNI_REGION="$region"
    printf '%s\n' "$region"
    return 0
  fi
  SERVER_REGION_HINT=""
  RESOLVED_SNI_REGION="$(guess_sni_region "${SERVER_IP:-}")"
  printf '%s\n' "$RESOLVED_SNI_REGION"
}

parse_sni_candidate_row() {
  local row="$1"
  SNI_ROW_REGION="$(awk -F'|' '{print $1}' <<<"$row")"
  SNI_ROW_DOMAIN="$(awk -F'|' '{print $2}' <<<"$row")"
  SNI_ROW_PENALTY="$(awk -F'|' '{print $3}' <<<"$row")"
  [[ -n "$SNI_ROW_REGION" && -n "$SNI_ROW_DOMAIN" && "$SNI_ROW_PENALTY" =~ ^[0-9]+$ ]]
}

pick_sni_candidate_rows() {
  local rows="$1"
  local region="${2:-global}"
  printf '%s\n' "$rows" | awk -F'|' -v region="$region" '
    $1==region || $1=="global" || (region=="jp" && $1=="asia")
  '
}

validate_sni_domain() {
  local domain="$1"
  [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

sni_tls_output_passes() {
  local output="$1"
  local domain="$2"
  printf '%s\n' "$output" | grep -qi 'TLSv1.3' || return 1
  printf '%s\n' "$output" | grep -i 'Server Temp Key' | grep -qi 'X25519' || return 1
  printf '%s\n' "$output" | grep -qi 'ALPN protocol: h2' || return 1
  printf '%s\n' "$output" | grep -qi 'Verify return code: 0 (ok)' || return 1
  sni_cert_matches "$output" "$domain"
}

sni_cert_matches() {
  local output="$1"
  local domain="$2"
  local parent wildcard
  parent="${domain#*.}"
  wildcard="*.${parent}"
  if printf '%s\n' "$output" | grep -qi 'subject='; then
    printf '%s\n' "$output" | grep -i 'subject=' | grep -Fqi "$domain" && return 0
    printf '%s\n' "$output" | grep -i 'subject=' | grep -Fqi "$wildcard" && return 0
  fi
  if printf '%s\n' "$output" | grep -qi 'DNS:'; then
    printf '%s\n' "$output" | grep -Fqi "DNS:$domain" && return 0
    printf '%s\n' "$output" | grep -Fqi "DNS:$wildcard" && return 0
  fi
  return 1
}

http_redirect_penalty() {
  local domain="$1"
  local headers location_host
  command_exists curl || {
    printf '0\n'
    return 0
  }
  headers="$(curl -IL --max-time 7 "https://${domain}" 2>/dev/null || true)"
  location_host="$(printf '%s\n' "$headers" | awk 'BEGIN{IGNORECASE=1} /^location:/ {print $2; exit}' | sed -E 's#https?://([^/[:space:]]+).*#\1#; s/\r//')"
  if [[ -n "$location_host" && "$location_host" != "$domain" ]]; then
    printf '500\n'
  else
    printf '0\n'
  fi
}

check_sni_candidate() {
  local domain="$1"
  local penalty="${2:-0}"
  local start end elapsed output redirect_penalty total_penalty
  validate_sni_domain "$domain" || {
    printf '%s|fail|999999|999999|bad-domain\n' "$domain"
    return 0
  }
  command_exists openssl || {
    printf '%s|pass|999|%s|openssl-missing-soft-pass\n' "$domain" "$penalty"
    return 0
  }
  start="$(now_ms)"
  output="$(printf '' | openssl s_client -connect "${domain}:443" -servername "$domain" -tls1_3 -alpn h2 2>&1 </dev/null || true)"
  end="$(now_ms)"
  elapsed=$((end - start))
  if sni_tls_output_passes "$output" "$domain"; then
    redirect_penalty="$(http_redirect_penalty "$domain")"
    total_penalty=$((penalty + redirect_penalty))
    printf '%s|pass|%s|%s|strict-ok\n' "$domain" "$elapsed" "$total_penalty"
  else
    printf '%s|fail|%s|999999|strict-check-failed\n' "$domain" "$elapsed"
  fi
}

select_best_sni_row() {
  local rows="$1"
  printf '%s\n' "$rows" |
    awk -F'|' '$2=="pass"{print ($3 + $4) "|" $1}' |
    sort -n |
    head -n 1 |
    awk -F'|' '{print $2}'
}

format_sni_result() {
  local row="$1"
  awk -F'|' '{
    score = $3 + $4
    printf "%s %s %sms score=%s %s", $1, $2, $3, score, $5
  }' <<<"$row"
}

select_reality_sni() {
  local rows best row region domain penalty result
  rows=""
  if [[ "${SNI_FORCE_REFRESH_REGION:-0}" == "1" ]]; then
    refresh_sni_region >/dev/null
  else
    resolve_sni_region >/dev/null
  fi
  region="${RESOLVED_SNI_REGION:-global}"
  info "SNI 候选地区: $region"
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    parse_sni_candidate_row "$row" || continue
    domain="$SNI_ROW_DOMAIN"
    penalty="$SNI_ROW_PENALTY"
    info "严格检测 SNI: $domain"
    result="$(check_sni_candidate "$domain" "$penalty")"
    info "SNI 结果: $(format_sni_result "$result")"
    rows="${rows}${result}"$'\n'
  done < <(pick_sni_candidate_rows "$(default_sni_candidates)" "$region")
  best="$(select_best_sni_row "$rows")"
  if [[ -n "$best" ]]; then
    REALITY_SNI="$best"
    info "已选择 Reality SNI: $REALITY_SNI"
    return 0
  fi
  return 1
}

write_bbr_sysctl_file() {
  mkdir -p "$SYSCTL_DIR"
  cat >"$BBR_SYSCTL_FILE" <<'EOF_BBR'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF_BBR
}

enable_bbr_if_supported() {
  local virt available
  virt="$(detect_virtualization)"
  available="$(get_available_bbr_modules)"
  if ! can_enable_bbr "$virt" "$available"; then
    warn "当前环境不适合自动修改 BBR: virt=$virt available=$available"
    return 1
  fi
  write_bbr_sysctl_file
  sysctl --system >/dev/null 2>&1 || sysctl -p "$BBR_SYSCTL_FILE" >/dev/null 2>&1 || return 1
  info "BBR 已启用: $(get_current_bbr)"
}

write_systemd_service() {
  mkdir -p "$SYSTEMD_DIR"
  cat >"$SYSTEMD_DIR/$SERVICE_NAME.service" <<EOF_SERVICE
[Unit]
Description=FastVLESS sing-box service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SING_BOX_BIN run -c $CONFIG_FILE
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF_SERVICE
}

start_service() {
  if [[ "$(detect_init_system)" == "systemd" ]]; then
    write_systemd_service
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE_NAME"
  else
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      kill "$(cat "$PID_FILE")" 2>/dev/null || true
    fi
    nohup "$SING_BOX_BIN" run -c "$CONFIG_FILE" >>"$LOG_FILE" 2>&1 &
    printf '%s\n' "$!" >"$PID_FILE"
  fi
}

ss_listen_output_has_port() {
  local output="$1"
  local port="$2"
  valid_port "$port" || return 1
  printf '%s\n' "$output" | awk -v port="$port" '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ ":" port "$") {
          found = 1
        }
      }
    }
    END { exit found ? 0 : 1 }
  '
}

port_is_listening() {
  local port="$1"
  local output
  command_exists ss || return 2
  output="$(ss -ltnp 2>/dev/null || ss -ltn 2>/dev/null || true)"
  ss_listen_output_has_port "$output" "$port"
}

verify_runtime_listeners() {
  local tries port label port_label failed
  failed=0
  if ! command_exists ss; then
    warn "缺少 ss 命令，跳过本机监听检测"
    return 0
  fi
  for port_label in "${VLESS_PORT:-}:VLESS" "${LOCAL_SOCKS_PORT:-}:SOCKS5"; do
    port="${port_label%%:*}"
    label="${port_label#*:}"
    [[ -n "$port" ]] || continue
    [[ "$label" == "SOCKS5" && "${LOCAL_SOCKS_ENABLED:-0}" != "1" ]] && continue
    for tries in 1 2 3 4 5; do
      if port_is_listening "$port"; then
        info "$label 已监听端口: $port"
        break
      fi
      sleep 1
    done
    if ! port_is_listening "$port"; then
      warn "$label 端口未监听: $port"
      failed=1
    fi
  done
  return "$failed"
}

restart_service_and_verify() {
  start_service
  verify_runtime_listeners || die "服务启动后没有监听 VLESS 端口，请用菜单 7 查看日志"
}

disable_local_socks() {
  LOCAL_SOCKS_ENABLED="0"
  LOCAL_SOCKS_LISTEN="127.0.0.1"
  LOCAL_SOCKS_PORT=""
  LOCAL_SOCKS_PUBLIC_PORT=""
  LOCAL_SOCKS_USER=""
  LOCAL_SOCKS_PASS=""
}

enable_local_socks_default() {
  LOCAL_SOCKS_ENABLED="1"
  LOCAL_SOCKS_LISTEN="${LOCAL_SOCKS_LISTEN:-127.0.0.1}"
  [[ -n "${LOCAL_SOCKS_PORT:-}" ]] || LOCAL_SOCKS_PORT="$(choose_random_port)"
  LOCAL_SOCKS_PUBLIC_PORT="${LOCAL_SOCKS_PUBLIC_PORT:-$LOCAL_SOCKS_PORT}"
  LOCAL_SOCKS_USER="${LOCAL_SOCKS_USER:-fv$(random_hex 3)}"
  LOCAL_SOCKS_PASS="${LOCAL_SOCKS_PASS:-$(random_password)}"
}

stop_service() {
  if [[ "$(detect_init_system)" == "systemd" ]] && [[ -f "$SYSTEMD_DIR/$SERVICE_NAME.service" ]]; then
    systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  elif [[ -f "$PID_FILE" ]]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f "$PID_FILE"
  fi
}

menu_text() {
  cat <<'EOF_MENU'
1. 推荐一键安装/修复
2. 查看 VLESS 链接
3. 配置上游 SOCKS5 出站
4. 开启/关闭本机 SOCKS5 导出
5. 重新优选 Reality SNI
6. 一键 BBR/查看加速状态
7. 查看服务状态/日志
8. 卸载
0. 退出
EOF_MENU
}

initialize_defaults() {
  UUID="${UUID:-}"
  VLESS_PORT="${VLESS_PORT:-}"
  PUBLIC_VLESS_PORT="${PUBLIC_VLESS_PORT:-$VLESS_PORT}"
  REALITY_SNI="${REALITY_SNI:-}"
  REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-}"
  REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-}"
  REALITY_SHORT_ID="${REALITY_SHORT_ID:-}"
  SERVER_IP="${SERVER_IP:-}"
  SERVER_REGION_HINT="${SERVER_REGION_HINT:-}"
  UPSTREAM_SOCKS_ENABLED="${UPSTREAM_SOCKS_ENABLED:-0}"
  LOCAL_SOCKS_ENABLED="${LOCAL_SOCKS_ENABLED:-0}"
  LOCAL_SOCKS_LISTEN="${LOCAL_SOCKS_LISTEN:-127.0.0.1}"
  LOCAL_SOCKS_PORT="${LOCAL_SOCKS_PORT:-}"
  LOCAL_SOCKS_PUBLIC_PORT="${LOCAL_SOCKS_PUBLIC_PORT:-$LOCAL_SOCKS_PORT}"
  LOCAL_SOCKS_USER="${LOCAL_SOCKS_USER:-fv$(random_hex 3)}"
  LOCAL_SOCKS_PASS="${LOCAL_SOCKS_PASS:-$(random_password)}"
}

prompt_yes_no() {
  local question="$1"
  local default="${2:-n}"
  local answer
  while :; do
    read -r -p "$question [$default]: " answer
    answer="$(trim_input "$answer")"
    answer="${answer:-$default}"
    case "$answer" in
      y|Y) return 0 ;;
      n|N) return 1 ;;
      *) warn "请输入 y 或 n，直接回车使用默认值 $default" >&2 ;;
    esac
  done
}

choose_random_port() {
  local port
  while :; do
    port="$((RANDOM % 40000 + 20000))"
    if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$port$"; then
      printf '%s\n' "$port"
      return 0
    fi
  done
}

select_port() {
  local label="$1"
  local default_port="$2"
  local input
  while :; do
    read -r -p "$label 端口，回车使用随机端口 $default_port: " input
    input="$(trim_input "$input")"
    input="${input:-$default_port}"
    if valid_port "$input"; then
      printf '%s\n' "$input"
      return 0
    fi
    warn "端口不正确，请输入 1-65535" >&2
  done
}

get_public_ip() {
  local ip
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    if command_exists curl; then
      ip="$(curl -fsS --max-time 5 "$url" 2>/dev/null || true)"
    elif command_exists wget; then
      ip="$(wget -qO- --timeout=5 "$url" 2>/dev/null || true)"
    else
      ip=""
    fi
    if [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  return 1
}

generate_uuid() {
  if [[ -x "$SING_BOX_BIN" ]]; then
    "$SING_BOX_BIN" generate uuid
  elif command_exists uuidgen; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    printf '%s-%s-%s-%s-%s\n' "$(random_hex 4)" "$(random_hex 2)" "$(random_hex 2)" "$(random_hex 2)" "$(random_hex 6)"
  fi
}

recommended_install() {
  [[ "$(id -u)" -eq 0 ]] || die "请使用 root 运行"
  preflight_space_check
  mkdir -p "$BASE_DIR"
  chmod 700 "$BASE_DIR"
  load_state
  initialize_defaults
  install_sing_box_binary "$SING_BOX_VERSION_DEFAULT"
  UUID="${UUID:-$(generate_uuid)}"
  VLESS_PORT="$(select_port "VLESS Reality" "${VLESS_PORT:-$(choose_random_port)}")"
  PUBLIC_VLESS_PORT="$VLESS_PORT"
  if prompt_yes_no "公网连接端口是否和本机监听端口不同（NAT 映射机器才需要）" "n"; then
    PUBLIC_VLESS_PORT="$(select_port "VLESS Reality 公网映射" "$VLESS_PORT")"
  fi
  SERVER_IP="${SERVER_IP:-$(get_public_ip || true)}"
  [[ -n "$SERVER_IP" ]] || read -r -p "未能自动识别公网 IP，请输入服务器 IP: " SERVER_IP
  generate_reality_values
  if ! select_reality_sni; then
    read -r -p "自动选择 SNI 失败，请输入 Reality SNI: " REALITY_SNI
    validate_sni_domain "$REALITY_SNI" || die "SNI 格式不正确"
  fi
  if prompt_yes_no "是否配置外部 SOCKS5 作为上游出口" "n"; then
    local upstream
    read -r -p "请输入 socks5://host:port:user:pass 或 socks5://user:pass@host:port: " upstream
    configure_upstream_socks_from_uri "$upstream" || die "SOCKS5 格式不正确"
  fi
  if prompt_yes_no "是否导出本机 SOCKS5 给其他工具使用" "n"; then
    LOCAL_SOCKS_ENABLED="1"
    LOCAL_SOCKS_PORT="$(select_port "本机 SOCKS5" "${LOCAL_SOCKS_PORT:-$(choose_random_port)}")"
    if prompt_yes_no "是否允许公网访问本机 SOCKS5" "n"; then
      LOCAL_SOCKS_LISTEN="::"
      if prompt_yes_no "SOCKS5 公网连接端口是否和本机监听端口不同（NAT 映射机器才需要）" "n"; then
        LOCAL_SOCKS_PUBLIC_PORT="$(select_port "SOCKS5 公网映射" "$LOCAL_SOCKS_PORT")"
      else
        LOCAL_SOCKS_PUBLIC_PORT="$LOCAL_SOCKS_PORT"
      fi
    else
      LOCAL_SOCKS_LISTEN="127.0.0.1"
      LOCAL_SOCKS_PUBLIC_PORT="$LOCAL_SOCKS_PORT"
    fi
  else
    disable_local_socks
  fi
  if prompt_yes_no "是否一键启用保守 BBR 加速" "y"; then
    enable_bbr_if_supported || true
  fi
  save_state
  write_config "$CONFIG_FILE"
  validate_config_if_possible "$CONFIG_FILE"
  restart_service_and_verify
  write_links
  show_links
}

show_links() {
  load_state
  if [[ -f "$LINKS_FILE" && "${LOCAL_SOCKS_ENABLED:-0}" == "1" ]]; then
    cat "$LINKS_FILE"
  else
    build_vless_link
    if [[ "${LOCAL_SOCKS_ENABLED:-0}" == "1" ]]; then
      build_socks_links
    fi
  fi
}

show_status() {
  printf '配置目录: %s\n' "$BASE_DIR"
  printf '当前 BBR: %s\n' "$(get_current_bbr || true)"
  load_state
  printf 'VLESS 本机端口: %s\n' "${VLESS_PORT:-未配置}"
  printf 'VLESS 公网端口: %s\n' "${PUBLIC_VLESS_PORT:-${VLESS_PORT:-未配置}}"
  printf 'Reality SNI: %s\n' "${REALITY_SNI:-未配置}"
  if command_exists ss; then
    printf '监听状态:\n'
    ss -ltnp 2>/dev/null | grep -E ":(${VLESS_PORT:-0}|${LOCAL_SOCKS_PORT:-0})\\b" || true
  fi
  if [[ "$(detect_init_system)" == "systemd" ]]; then
    systemctl status "$SERVICE_NAME" --no-pager || true
    journalctl -u "$SERVICE_NAME" -n 50 --no-pager || true
  else
    [[ -f "$PID_FILE" ]] && printf 'PID: %s\n' "$(cat "$PID_FILE")"
    tail -n 50 "$LOG_FILE" 2>/dev/null || true
  fi
}

uninstall_fastvless() {
  stop_service
  rm -f "$SYSTEMD_DIR/$SERVICE_NAME.service"
  rm -rf "$BASE_DIR"
  if prompt_yes_no "是否移除 FastVLESS 写入的 BBR 配置" "n"; then
    rm -f "$BBR_SYSCTL_FILE"
    sysctl --system >/dev/null 2>&1 || true
  fi
  info "已卸载 FastVLESS"
}

main_menu() {
  local choice upstream_input
  while :; do
    print_banner
    menu_text
    read -r -p "请选择: " choice
    case "$choice" in
      1) recommended_install ;;
      2) show_links ;;
      3) read -r -p "请输入上游 SOCKS5: " upstream_input; configure_upstream_socks_from_uri "$upstream_input" && write_config "$CONFIG_FILE" && restart_service_and_verify && write_links ;;
      4) load_state; initialize_defaults; if [[ "${LOCAL_SOCKS_ENABLED:-0}" == "1" ]]; then disable_local_socks; else enable_local_socks_default; fi; save_state; write_config "$CONFIG_FILE"; restart_service_and_verify; write_links; show_links ;;
      5) load_state; SNI_FORCE_REFRESH_REGION=1 select_reality_sni || die "SNI 重新选择失败"; save_state; write_config "$CONFIG_FILE"; restart_service_and_verify; write_links; show_links ;;
      6) enable_bbr_if_supported || true ;;
      7) show_status ;;
      8) uninstall_fastvless ;;
      0) exit 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

main() {
  main_menu
}

if [[ "${FASTVLESS_TEST_MODE:-0}" != "1" ]]; then
  main "$@"
fi
