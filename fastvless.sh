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

main() {
  printf '%s\n' "FastVLESS"
}

if [[ "${FASTVLESS_TEST_MODE:-0}" != "1" ]]; then
  main "$@"
fi
