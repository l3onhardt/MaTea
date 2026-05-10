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
www.microsoft.com
www.apple.com
www.cloudflare.com
www.samsung.com
www.oracle.com
www.cisco.com
www.ibm.com
www.mozilla.org
www.bing.com
EOF_SNI
}

validate_sni_domain() {
  local domain="$1"
  [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

check_sni_candidate() {
  local domain="$1"
  local start end elapsed output
  validate_sni_domain "$domain" || {
    printf '%s|fail|999999\n' "$domain"
    return 0
  }
  command_exists openssl || {
    printf '%s|pass|999\n' "$domain"
    return 0
  }
  start="$(date +%s%3N 2>/dev/null || date +%s)"
  output="$(printf '' | timeout 6 openssl s_client -connect "${domain}:443" -servername "$domain" -tls1_3 -alpn h2 -brief 2>&1 || true)"
  end="$(date +%s%3N 2>/dev/null || date +%s)"
  elapsed=$((end - start))
  if printf '%s\n' "$output" | grep -qiE 'Protocol version: TLSv1.3|Protocol *: TLSv1.3|CONNECTION ESTABLISHED'; then
    printf '%s|pass|%s\n' "$domain" "$elapsed"
  else
    printf '%s|fail|%s\n' "$domain" "$elapsed"
  fi
}

select_best_sni_row() {
  local rows="$1"
  printf '%s\n' "$rows" |
    awk -F'|' '$2=="pass"{print $3 "|" $1}' |
    sort -n |
    head -n 1 |
    awk -F'|' '{print $2}'
}

select_reality_sni() {
  local rows best domain
  rows=""
  while IFS= read -r domain; do
    [[ -n "$domain" ]] || continue
    info "检测 SNI: $domain"
    rows="${rows}$(check_sni_candidate "$domain")"$'\n'
  done < <(default_sni_candidates)
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
    systemctl enable --now "$SERVICE_NAME"
  else
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      kill "$(cat "$PID_FILE")" 2>/dev/null || true
    fi
    nohup "$SING_BOX_BIN" run -c "$CONFIG_FILE" >>"$LOG_FILE" 2>&1 &
    printf '%s\n' "$!" >"$PID_FILE"
  fi
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

FastVLESS
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
  read -r -p "$question [$default]: " answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy]$ ]]
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
  VLESS_PORT="${VLESS_PORT:-$(choose_random_port)}"
  PUBLIC_VLESS_PORT="${PUBLIC_VLESS_PORT:-$VLESS_PORT}"
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
    LOCAL_SOCKS_PORT="${LOCAL_SOCKS_PORT:-$(choose_random_port)}"
    if prompt_yes_no "是否允许公网访问本机 SOCKS5" "n"; then
      LOCAL_SOCKS_LISTEN="::"
    else
      LOCAL_SOCKS_LISTEN="127.0.0.1"
    fi
  fi
  if prompt_yes_no "是否一键启用保守 BBR 加速" "y"; then
    enable_bbr_if_supported || true
  fi
  save_state
  write_config "$CONFIG_FILE"
  validate_config_if_possible "$CONFIG_FILE"
  start_service
  write_links
  show_links
}

show_links() {
  load_state
  if [[ -f "$LINKS_FILE" ]]; then
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
    menu_text
    read -r -p "请选择: " choice
    case "$choice" in
      1) recommended_install ;;
      2) show_links ;;
      3) read -r -p "请输入上游 SOCKS5: " upstream_input; configure_upstream_socks_from_uri "$upstream_input" && write_config "$CONFIG_FILE" && start_service && write_links ;;
      4) load_state; initialize_defaults; if [[ "${LOCAL_SOCKS_ENABLED:-0}" == "1" ]]; then LOCAL_SOCKS_ENABLED="0"; else LOCAL_SOCKS_ENABLED="1"; fi; save_state; write_config "$CONFIG_FILE"; start_service; write_links; show_links ;;
      5) load_state; select_reality_sni || die "SNI 重新选择失败"; save_state; write_config "$CONFIG_FILE"; start_service; write_links; show_links ;;
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
