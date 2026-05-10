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

main() {
  printf '%s\n' "FastVLESS"
}

if [[ "${FASTVLESS_TEST_MODE:-0}" != "1" ]]; then
  main "$@"
fi
