#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="fastvless"
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
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >>"$LOG_FILE" 2>/dev/null || true
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

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

valid_port() {
  local port="${1:-}"
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
      "listen": "::",
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

main() {
  printf '%s\n' "FastVLESS"
}

if [[ "${FASTVLESS_TEST_MODE:-0}" != "1" ]]; then
  main "$@"
fi
