#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP_NAME="xhttp-cdn-deploy"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
. "${SCRIPT_DIR}/runtime-versions.sh"
DEFAULT_SHORT_ID="a1234567"
DEFAULT_XHTTP_PATH="/xhttp"
PORTS=(2053 2083 2087 2096)
CDN_PORTS=("${PORTS[@]}")
SKIPPED_CDN_PORTS=()
declare -A CDN_SKIP_REASONS=()
ACME_INSTALL_URL="https://get.acme.sh"
XRAY_INSTALL_REF=""
XRAY_VERSION=""
ACME_VERSION=""
XRAY_VERSION_INSTALLED=""
ACME_VERSION_INSTALLED="unavailable"
NGINX_VERSION_INSTALLED=""
DEBIAN_PACKAGE_VERSIONS=""
COMPONENTS_UPDATED_UTC=""
DEBIAN_PACKAGES=(ca-certificates curl cron iproute2 jq nginx openssl unzip)

DRY_RUN=0
DRY_RUN_OUTPUT=""
PROMPT_FD=0

STATE_DIR="/etc/xhttp-cdn-deploy"
XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"
NGINX_CONF_PATH="/etc/nginx/conf.d/xhttp-cdn-deploy.conf"
CLIENT_DIR="/root/xhttp-cdn-deploy"
CLIENT_FILE="${CLIENT_DIR}/client-v2rayn.txt"
CERT_DIR="${STATE_DIR}/tls"
CERT_FILE="${CERT_DIR}/fullchain.pem"
KEY_FILE="${CERT_DIR}/privkey.pem"
SITE_DIR="/var/www/xhttp-cdn-deploy"
ACME_HOME="/root/.acme.sh"
DIRECT_PORT=""
INSTALL_STATE_FILE="${STATE_DIR}/install-state.env"
PACKAGE_BASELINE_FILE="${STATE_DIR}/packages.before"
BACKUP_DIR="${STATE_DIR}/backups"
OWNED_PACKAGES=""
XRAY_INSTALLED_BY_TOOL=0
XRAY_USER_CREATED_BY_TOOL=0
XRAY_GROUP_CREATED_BY_TOOL=0
XRAY_SERVICE_FILE=""
XRAY_SERVICE_SHA256=""
XRAY_BINARY_SHA256=""
XRAY_SERVICE_USER=""
XRAY_SERVICE_GROUP=""
XRAY_CONFIG_MODE=""
ACME_INSTALLED_BY_TOOL=0
ACME_CERT_ISSUED_BY_TOOL=0
ACME_DOMAIN=""
XRAY_CONFIG_BACKUP=""
NGINX_CONFIG_BACKUP=""
CLIENT_FILE_BACKUP=""
SITE_DIR_CREATED_BY_TOOL=0
SITE_INDEX_CREATED_BY_TOOL=0
SITE_INDEX_SHA256=""
XRAY_CONFIG_SHA256=""
NGINX_CONFIG_SHA256=""
CLIENT_FILE_SHA256=""
NODE_NAMES=()
NODE_ALIAS_BASE=""

log()  { printf '[INFO] %s\n' "$*"; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo bash deploy.sh
  sudo bash deploy.sh --dry-run OUTPUT_DIR

The dry-run mode renders configs without installing packages or changing system files.
EOF
}

on_error() {
  local status=$?
  printf '[ERROR] deployment failed near line %s (exit %s)\n' "${1:-?}" "$status" >&2
  exit "$status"
}
trap 'on_error "$LINENO"' ERR

parse_args() {
  case "${1:-}" in
    "") ;;
    --help|-h)
      usage
      exit 0
      ;;
    --dry-run)
      DRY_RUN=1
      DRY_RUN_OUTPUT="${2:-}"
      [[ -n "$DRY_RUN_OUTPUT" ]] || die "--dry-run requires an output directory"
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
}

init_paths() {
  if (( DRY_RUN )); then
    mkdir -p "$DRY_RUN_OUTPUT"
    DRY_RUN_OUTPUT="$(cd "$DRY_RUN_OUTPUT" && pwd -P)"
    STATE_DIR="${DRY_RUN_OUTPUT}/state"
    XRAY_CONFIG_PATH="${DRY_RUN_OUTPUT}/xray-config.json"
    NGINX_CONF_PATH="${DRY_RUN_OUTPUT}/nginx.conf"
    CLIENT_DIR="$DRY_RUN_OUTPUT"
    CLIENT_FILE="${DRY_RUN_OUTPUT}/client-v2rayn.txt"
    CERT_DIR="${DRY_RUN_OUTPUT}/tls"
    CERT_FILE="${CERT_DIR}/fullchain.pem"
    KEY_FILE="${CERT_DIR}/privkey.pem"
    SITE_DIR="${DRY_RUN_OUTPUT}/site"
    ACME_HOME="${DRY_RUN_OUTPUT}/acme"
  fi
}

open_prompt_fd() {
  if (( ! DRY_RUN )) && [[ -r /dev/tty ]]; then
    exec {PROMPT_FD}<>/dev/tty
  else
    PROMPT_FD=0
  fi
}

prompt_value() {
  local variable="$1"
  local message="$2"
  local default_value="${3:-}"
  local answer

  if [[ -n "$default_value" ]]; then
    if ! read -r -u "$PROMPT_FD" -p "$message [$default_value]: " answer; then
      die "input ended while reading ${variable}"
    fi
    answer="${answer:-$default_value}"
  else
    if ! read -r -u "$PROMPT_FD" -p "$message: " answer; then
      die "input ended while reading ${variable}"
    fi
  fi
  printf -v "$variable" '%s' "$answer"
}

prompt_yes_no() {
  local message="$1"
  local default_value="${2:-N}"
  local answer
  while :; do
    if ! read -r -u "$PROMPT_FD" -p "$message [y/N]: " answer; then
      die "input ended while reading confirmation"
    fi
    answer="${answer:-$default_value}"
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) printf '[ERROR] 请输入 y/yes 或 n/no。\n' >&2 ;;
    esac
  done
}

valid_domain() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
  [[ "$value" != *..* && "$value" != *.-* && "$value" != *-.* ]] || return 1
  [[ "$value" == *.* ]] || return 1
  return 0
}

valid_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

valid_ipv4() {
  local value="$1"
  local IFS=.
  local -a octets
  read -r -a octets <<< "$value"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  local octet
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#$octet <= 255 )) || return 1
  done
  return 0
}

valid_short_id() {
  [[ "$1" =~ ^([0-9a-fA-F]{2}){1,8}$ ]]
}

valid_xhttp_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._~/-]+$ ]]
}

wildcard_san_covers() {
  local domain="$1"
  local suffix="$2"
  local label
  [[ "$domain" == *."$suffix" ]] || return 1
  label="${domain%.$suffix}"
  [[ -n "$label" && "$label" != *.* ]]
}

require_debian_root() {
  (( DRY_RUN )) && return 0
  [[ $EUID -eq 0 ]] || die "run this script as root"
  [[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == debian ]] || die "only Debian 12 or Debian 13 is supported"
  [[ "${VERSION_ID:-}" =~ ^(12|13)(\.|$) ]] ||
    die "only Debian 12 or Debian 13 is supported"
  command -v systemctl >/dev/null 2>&1 || die "systemd is required"
}

detect_ipv4() {
  if (( DRY_RUN )); then
    printf '%s' "${XHTTP_TEST_IP:-198.51.100.10}"
  else
    curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true
  fi
}

port_listener_details() {
  local port="$1" hex matches
  if command -v ss >/dev/null 2>&1; then
    ss -H -ltnp "( sport = :${port} )" 2>/dev/null || true
    return 0
  fi

  hex="$(printf '%04X' "$port")"
  matches="$(awk -v wanted="$hex" '
    NR > 1 {
      split($2, endpoint, ":")
      if (toupper(endpoint[2]) == wanted) print
    }
  ' /proc/net/tcp /proc/net/tcp6 2>/dev/null || true)"
  if [[ -n "$matches" ]]; then
    printf 'listener on TCP port %s (process owner unavailable; iproute2/ss is not installed)\n' "$port"
  fi
}

listener_is_nginx() {
  local details="$1" line marker='users:(("nginx",'
  [[ -n "$details" ]] || return 1
  while IFS= read -r line; do
    [[ "$line" == *"$marker"* ]] || return 1
  done <<< "$details"
}

check_required_port() {
  local port="$1" allow_nginx="$2" details
  details="$(port_listener_details "$port")"
  [[ -z "$details" ]] && return 0
  if (( allow_nginx )) && listener_is_nginx "$details"; then
    log "reusing Nginx listener on local TCP port ${port}"
    return 0
  fi
  printf '[ERROR] TCP port %s is already in use:\n%s\n' "$port" "$details" >&2
  return 1
}

check_reality_ports() {
  (( DRY_RUN )) && return 0
  check_required_port "$DIRECT_PORT" 0 || {
    printf '[ERROR] Reality 直连端口被占用，无法跳过唯一的直连节点。\n' >&2
    return 1
  }
  check_required_port "$((DIRECT_PORT + 10000))" 1 || {
    printf '[ERROR] Reality 回落端口被非 Nginx 服务占用，无法安全启动直连节点。\n' >&2
    return 1
  }
}

select_cdn_ports() {
  local port internal_port details reason
  CDN_PORTS=()
  SKIPPED_CDN_PORTS=()
  CDN_SKIP_REASONS=()

  if (( DRY_RUN )); then
    CDN_PORTS=("${PORTS[@]}")
    return 0
  fi

  for port in "${PORTS[@]}"; do
    internal_port=$((port + 10000))
    reason=""
    details="$(port_listener_details "$port")"
    if [[ -n "$details" ]] && ! listener_is_nginx "$details"; then
      reason="公网端口 ${port} 已被非 Nginx 服务占用"
    fi
    details="$(port_listener_details "$internal_port")"
    if [[ -n "$details" ]]; then
      if [[ -n "$reason" ]]; then
        reason+="；本机转发端口 ${internal_port} 也已被占用"
      else
        reason="本机转发端口 ${internal_port} 已被占用"
      fi
    fi
    if [[ -n "$reason" ]]; then
      SKIPPED_CDN_PORTS+=("$port")
      CDN_SKIP_REASONS["$port"]="$reason"
      printf '[WARN] 跳过 CDN 端口 %s：%s。\n' "$port" "$reason" >&2
    else
      CDN_PORTS+=("$port")
    fi
  done

  if ((${#CDN_PORTS[@]} == 0)); then
    printf '[WARN] 四个 CDN 端口均不可用，将只部署 Reality 直连节点。\n' >&2
  fi
}

cdn_uuid_for_port() {
  case "$1" in
    2053) printf '%s' "${UUIDS[1]}" ;;
    2083) printf '%s' "${UUIDS[2]}" ;;
    2087) printf '%s' "${UUIDS[3]}" ;;
    2096) printf '%s' "${UUIDS[4]}" ;;
    *) return 1 ;;
  esac
}

cdn_node_name_for_port() {
  case "$1" in
    2053) printf '%s' "${NODE_NAMES[1]}" ;;
    2083) printf '%s' "${NODE_NAMES[2]}" ;;
    2087) printf '%s' "${NODE_NAMES[3]}" ;;
    2096) printf '%s' "${NODE_NAMES[4]}" ;;
    *) return 1 ;;
  esac
}

ports_as_space_list() {
  local IFS=' '
  printf '%s' "$*"
}

collect_inputs() {
  local detected_ip port value index previous prompt_label
  REALITY_DOMAIN=""
  CDN_DOMAIN=""

  printf '\n%s\n' "${APP_NAME}: one Reality node and up to four CDN nodes"
  printf '%s\n' "请将 a2 灰云域名用于 Reality；a1 橙云域名用于四个 CDN 端口。证书同时覆盖两者。"
  while :; do
    prompt_value REALITY_DOMAIN "Reality 灰云域名（a2）/ SNI"
    REALITY_DOMAIN="${REALITY_DOMAIN,,}"
    if valid_domain "$REALITY_DOMAIN"; then break; fi
    printf '[ERROR] Reality 域名格式无效，请重新输入。\n' >&2
  done
  while :; do
    prompt_value CDN_DOMAIN "Cloudflare 橙云 CDN 域名（a1）"
    CDN_DOMAIN="${CDN_DOMAIN,,}"
    if ! valid_domain "$CDN_DOMAIN"; then
      printf '[ERROR] CDN 域名格式无效，请重新输入。\n' >&2
    elif [[ "$REALITY_DOMAIN" == "$CDN_DOMAIN" ]]; then
      printf '[ERROR] Reality 域名和 CDN 域名必须不同，请重新输入 CDN 域名。\n' >&2
    else
      break
    fi
  done

  while :; do
    prompt_value DIRECT_PORT "上下行均直连 Reality 的端口（须与 2053/2083/2087/2096 不同）"
    if [[ ! "$DIRECT_PORT" =~ ^[0-9]{1,5}$ ]]; then
      printf '[ERROR] 端口必须是十进制 TCP 端口，请重新输入。\n' >&2
      continue
    fi
    DIRECT_PORT=$((10#$DIRECT_PORT))
    if (( DIRECT_PORT < 1 || DIRECT_PORT > 55535 )); then
      printf '[ERROR] 端口必须在 1 到 55535 之间，请重新输入。\n' >&2
      continue
    fi
    for port in "${PORTS[@]}"; do
      if [[ "$DIRECT_PORT" == "$port" || "$DIRECT_PORT" == "$((port + 10000))" ]]; then
        printf '[ERROR] 端口与 CDN 端口或其本机转发端口冲突，请重新输入。\n' >&2
        continue 2
      fi
    done
    break
  done

  detected_ip="$(detect_ipv4)"
  while :; do
    prompt_value VPS_IPV4 "VPS 公网 IPv4" "$detected_ip"
    if valid_ipv4 "$VPS_IPV4"; then break; fi
    printf '[ERROR] IPv4 地址格式无效，请重新输入。\n' >&2
  done

  check_reality_ports || die "Reality 直连端口检查失败"
  select_cdn_ports

  while :; do
    UUIDS=()
    printf '请粘贴五行不同的 UUID，顺序为 Reality 直连、2053、2083、2087、2096：\n' >&2
    if ! mapfile -t -n 5 -u "$PROMPT_FD" UUIDS; then
      die "could not read the five UUID lines"
    fi
    ((${#UUIDS[@]} == 5)) || die "exactly five UUID lines are required"
    value=""
    for index in 0 1 2 3 4; do
      value="${UUIDS[$index]%$'\r'}"
      UUIDS[$index]="$value"
      if (( index == 0 )); then
        prompt_label="Reality 直连节点 UUID"
      else
        prompt_label="端口 ${PORTS[$((index - 1))]} CDN 节点 UUID"
      fi
      if ! valid_uuid "$value"; then
        printf '[ERROR] %s 格式无效，请重新粘贴五行 UUID。\n' "$prompt_label" >&2
        continue 2
      fi
      for previous in "${UUIDS[@]:0:index}"; do
        if [[ "${previous,,}" == "${value,,}" ]]; then
          printf '[ERROR] UUID 必须互不相同，请重新粘贴五行 UUID。\n' >&2
          continue 3
        fi
      done
    done
    break
  done

  while :; do
    prompt_value REALITY_PRIVATE_KEY "Reality 私钥（base64url；输入可见）"
    if [[ "$REALITY_PRIVATE_KEY" =~ ^[A-Za-z0-9_-]+$ ]]; then break; fi
    printf '[ERROR] Reality 私钥必须是非空 base64url 字符串，请重新输入。\n' >&2
  done

  while :; do
    prompt_value REALITY_SHORT_ID "Reality Short ID" "$DEFAULT_SHORT_ID"
    if valid_short_id "$REALITY_SHORT_ID"; then break; fi
    printf '[ERROR] Short ID 必须是 2-16 位偶数长度十六进制字符，请重新输入。\n' >&2
  done

  while :; do
    prompt_value XHTTP_PATH "XHTTP 路径" "$DEFAULT_XHTTP_PATH"
    if valid_xhttp_path "$XHTTP_PATH"; then break; fi
    printf '[ERROR] XHTTP 路径格式无效，请重新输入。\n' >&2
  done

  prompt_value NODE_ALIAS_BASE "节点的基础别名（将自动追加端口号）" "xhttp"
  NODE_NAMES=(
    "${NODE_ALIAS_BASE}-${DIRECT_PORT}"
    "${NODE_ALIAS_BASE}-2053"
    "${NODE_ALIAS_BASE}-2083"
    "${NODE_ALIAS_BASE}-2087"
    "${NODE_ALIAS_BASE}-2096"
  )
}

install_packages() {
  (( DRY_RUN )) && return 0
  log "installing Debian dependencies"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends "${DEBIAN_PACKAGES[@]}"
  local installed_packages
  installed_packages="$(dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' |
    awk -F '\t' '$2 == "installed" { print $1 }' | sort -u)"
  OWNED_PACKAGES="$(comm -13 "${STATE_DIR}/packages.before" <(printf '%s\n' "$installed_packages" | sed '/^$/d'))"
  write_install_state
}

write_install_state() {
  (( DRY_RUN )) && return 0
  local temporary="${INSTALL_STATE_FILE}.tmp"
  {
    printf 'STATE_VERSION=3\n'
    printf 'XRAY_INSTALLER_COMMIT=%q\n' "$XRAY_INSTALL_REF"
    printf 'XRAY_VERSION_RESOLVED=%q\n' "$XRAY_VERSION"
    printf 'ACME_VERSION_RESOLVED=%q\n' "$ACME_VERSION"
    printf 'XRAY_VERSION_INSTALLED=%q\n' "$XRAY_VERSION_INSTALLED"
    printf 'ACME_VERSION_INSTALLED=%q\n' "$ACME_VERSION_INSTALLED"
    printf 'NGINX_VERSION_INSTALLED=%q\n' "$NGINX_VERSION_INSTALLED"
    printf 'DEBIAN_PACKAGE_VERSIONS=%q\n' "$DEBIAN_PACKAGE_VERSIONS"
    printf 'COMPONENTS_UPDATED_UTC=%q\n' "$COMPONENTS_UPDATED_UTC"
    printf 'XRAY_INSTALLED_BY_TOOL=%q\n' "$XRAY_INSTALLED_BY_TOOL"
    printf 'XRAY_USER_CREATED_BY_TOOL=%q\n' "$XRAY_USER_CREATED_BY_TOOL"
    printf 'XRAY_GROUP_CREATED_BY_TOOL=%q\n' "$XRAY_GROUP_CREATED_BY_TOOL"
    printf 'XRAY_SERVICE_FILE=%q\n' "$XRAY_SERVICE_FILE"
    printf 'XRAY_SERVICE_SHA256=%q\n' "$XRAY_SERVICE_SHA256"
    printf 'XRAY_BINARY_SHA256=%q\n' "$XRAY_BINARY_SHA256"
    printf 'XRAY_SERVICE_USER=%q\n' "$XRAY_SERVICE_USER"
    printf 'XRAY_SERVICE_GROUP=%q\n' "$XRAY_SERVICE_GROUP"
    printf 'XRAY_CONFIG_MODE=%q\n' "$XRAY_CONFIG_MODE"
    printf 'ACME_INSTALLED_BY_TOOL=%q\n' "$ACME_INSTALLED_BY_TOOL"
    printf 'ACME_CERT_ISSUED_BY_TOOL=%q\n' "$ACME_CERT_ISSUED_BY_TOOL"
    printf 'ACME_DOMAIN=%q\n' "$ACME_DOMAIN"
    printf 'OWNED_PACKAGES=%q\n' "$OWNED_PACKAGES"
    printf 'PACKAGE_BASELINE_FILE=%q\n' "$PACKAGE_BASELINE_FILE"
    printf 'XRAY_CONFIG_BACKUP=%q\n' "$XRAY_CONFIG_BACKUP"
    printf 'NGINX_CONFIG_BACKUP=%q\n' "$NGINX_CONFIG_BACKUP"
    printf 'CLIENT_FILE_BACKUP=%q\n' "$CLIENT_FILE_BACKUP"
    printf 'CLIENT_FILE_CREATED_BY_TOOL=%q\n' "$([[ -z "$CLIENT_FILE_BACKUP" ]] && printf 1 || printf 0)"
    printf 'SITE_DIR_CREATED_BY_TOOL=%q\n' "$SITE_DIR_CREATED_BY_TOOL"
    printf 'SITE_INDEX_CREATED_BY_TOOL=%q\n' "$SITE_INDEX_CREATED_BY_TOOL"
    printf 'SITE_INDEX_SHA256=%q\n' "$SITE_INDEX_SHA256"
    printf 'XRAY_CONFIG_SHA256=%q\n' "$XRAY_CONFIG_SHA256"
    printf 'NGINX_CONFIG_SHA256=%q\n' "$NGINX_CONFIG_SHA256"
    printf 'CLIENT_FILE_SHA256=%q\n' "$CLIENT_FILE_SHA256"
    printf 'REALITY_DOMAIN=%q\n' "$REALITY_DOMAIN"
  } > "$temporary"
  chmod 600 "$temporary"
  mv -f "$temporary" "$INSTALL_STATE_FILE"
}

backup_file() {
  local path="$1"
  local variable="$2"
  [[ -e "$path" ]] || return 0
  local backup="${BACKUP_DIR}/$(basename "$path").original"
  cp -a "$path" "$backup"
  printf -v "$variable" '%s' "$backup"
}

initialize_install_state() {
  (( DRY_RUN )) && return 0
  if [[ -e "$STATE_DIR" ]]; then
    local state_reality_domain state_path
    state_path="$INSTALL_STATE_FILE"
    [[ -f "$state_path" && ! -L "$state_path" ]] ||
      die "${STATE_DIR} already exists without a resumable installation state"
    state_reality_domain="$REALITY_DOMAIN"
    # shellcheck disable=SC1090
    . "$state_path"
    [[ "${STATE_VERSION:-}" == 3 && "${XRAY_INSTALLED_BY_TOOL:-}" == 0 ]] ||
      die "an incomplete component installation exists; use uninstall.sh before retrying"
    [[ -f "$PACKAGE_BASELINE_FILE" ]] || die "the package baseline is missing; cannot safely resume"
    [[ ! -e /usr/local/bin/xray && ! -e /usr/local/etc/xray && ! -e /etc/systemd/system/xray.service ]] ||
      die "Xray installation has already started; use uninstall.sh before retrying"
    REALITY_DOMAIN="$state_reality_domain"
    log "resuming an incomplete dependency setup"
    return 0
  fi
  install -d -m 700 "$STATE_DIR" "$BACKUP_DIR"
  dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' |
    awk -F '\t' '$2 == "installed" { print $1 }' | sort -u > "$PACKAGE_BASELINE_FILE"
  backup_file "$XRAY_CONFIG_PATH" XRAY_CONFIG_BACKUP
  backup_file "$NGINX_CONF_PATH" NGINX_CONFIG_BACKUP
  backup_file "$CLIENT_FILE" CLIENT_FILE_BACKUP
  [[ -d "$SITE_DIR" ]] || SITE_DIR_CREATED_BY_TOOL=1
  if ! getent passwd xray >/dev/null; then XRAY_USER_CREATED_BY_TOOL=1; fi
  if ! getent group xray >/dev/null; then XRAY_GROUP_CREATED_BY_TOOL=1; fi
  if [[ ! -x "$ACME_HOME/acme.sh" ]]; then ACME_INSTALLED_BY_TOOL=1; fi
  write_install_state
}

require_fresh_xray() {
  (( DRY_RUN )) && return 0
  if [[ -e /usr/local/bin/xray || -d /usr/local/etc/xray ]] ||
     systemctl list-unit-files --no-legend xray.service 2>/dev/null | grep -q '^xray.service'; then
    die "an Xray installation already exists; refusing to overwrite it"
  fi
}

install_xray() {
  (( DRY_RUN )) && return 0
  log "installing official Xray-core ${XRAY_VERSION}"
  local installer
  installer="$(mktemp)"
  XRAY_INSTALLED_BY_TOOL=1
  write_install_state
  curl -fsSL "https://raw.githubusercontent.com/XTLS/Xray-install/${XRAY_INSTALL_REF}/install-release.sh" -o "$installer"
  if ! bash "$installer" install --version "$XRAY_VERSION"; then
    rm -f "$installer"
    die "official Xray installer failed"
  fi
  rm -f "$installer"
  [[ -x /usr/local/bin/xray ]] || die "Xray installation did not produce /usr/local/bin/xray"
  [[ -f /usr/local/bin/xray && ! -L /usr/local/bin/xray ]] || die "Xray binary is not a regular file"
  XRAY_BINARY_SHA256="$(sha256sum /usr/local/bin/xray | awk '{print $1}')"
  XRAY_VERSION_INSTALLED="$(/usr/local/bin/xray version 2>/dev/null | sed -n '1p')"
  if [[ -f "$XRAY_CONFIG_PATH" && ! -L "$XRAY_CONFIG_PATH" ]]; then
    XRAY_CONFIG_SHA256="$(sha256sum "$XRAY_CONFIG_PATH" | awk '{print $1}')"
  fi
  XRAY_SERVICE_FILE="$(systemctl show --property=FragmentPath --value xray.service 2>/dev/null || true)"
  if [[ -n "$XRAY_SERVICE_FILE" && -f "$XRAY_SERVICE_FILE" && ! -L "$XRAY_SERVICE_FILE" ]]; then
    XRAY_SERVICE_SHA256="$(sha256sum "$XRAY_SERVICE_FILE" | awk '{print $1}')"
  fi
  write_install_state
}

derive_public_key() {
  if (( DRY_RUN )); then
    PUBLIC_KEY="${XHTTP_TEST_PUBLIC_KEY:-test-public-key}"
    return 0
  fi

  local output
  while :; do
    if output="$(/usr/local/bin/xray x25519 -i "$REALITY_PRIVATE_KEY" 2>&1)"; then
      PUBLIC_KEY="$(awk -F': *' 'tolower($1) ~ /publickey/ { print $2; exit }' <<< "$output")"
      if [[ -n "$PUBLIC_KEY" ]]; then return 0; fi
    fi
    printf '[ERROR] Xray 拒绝了 Reality 私钥，请重新输入。\n' >&2
    prompt_value REALITY_PRIVATE_KEY "Reality 私钥（base64url；输入可见）"
    [[ "$REALITY_PRIVATE_KEY" =~ ^[A-Za-z0-9_-]+$ ]] ||
      printf '[ERROR] Reality 私钥必须是非空 base64url 字符串，请重新输入。\n' >&2
  done
}

ensure_state_dirs() {
  install -d -m 700 "$STATE_DIR" "$CERT_DIR" "$CLIENT_DIR"
  install -d -m 755 "$SITE_DIR"
  install -d -m 700 "$STATE_DIR/backups"
  if (( ! DRY_RUN )); then
    install -d -m 755 "$(dirname "$XRAY_CONFIG_PATH")" "$(dirname "$NGINX_CONF_PATH")"
  fi
}

certificate_contains_domain() {
  local certificate="$1"
  local domains
  domains="$(openssl x509 -in "$certificate" -noout -ext subjectAltName 2>/dev/null |
    tr ',' '\n' | sed -n 's/.*DNS:\([^, ]*\).*/\1/p' || true)"
  local candidate reality_covered=0 cdn_covered=0 suffix
  while IFS= read -r candidate; do
    candidate="${candidate//[[:space:]]/}"
    [[ "$candidate" == "$REALITY_DOMAIN" ]] && reality_covered=1
    [[ "$candidate" == "$CDN_DOMAIN" ]] && cdn_covered=1
    if [[ "$candidate" == \*.* ]]; then
      suffix="${candidate#\*.}"
      wildcard_san_covers "$REALITY_DOMAIN" "$suffix" && reality_covered=1
      wildcard_san_covers "$CDN_DOMAIN" "$suffix" && cdn_covered=1
    fi
  done <<< "$domains"
  (( reality_covered && cdn_covered ))
}

certificate_key_matches() {
  local certificate="$1"
  local private_key="$2"
  local certificate_hash key_hash
  certificate_hash="$(openssl x509 -in "$certificate" -pubkey -noout 2>/dev/null |
    openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')" || return 1
  key_hash="$(openssl pkey -in "$private_key" -pubout 2>/dev/null |
    openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')" || return 1
  [[ -n "$certificate_hash" && "$certificate_hash" == "$key_hash" ]]
}

certificate_is_usable() {
  local certificate="$1"
  local private_key="$2"
  [[ -s "$certificate" && -s "$private_key" ]] || return 1
  openssl x509 -in "$certificate" -noout -checkend 0 >/dev/null 2>&1 || return 1
  certificate_contains_domain "$certificate" || return 1
  certificate_key_matches "$certificate" "$private_key"
}

install_existing_certificate() {
  local source_certificate source_key
  while :; do
    prompt_value source_certificate "已有证书 PEM 绝对路径"
    if [[ "$source_certificate" != /* || ! -f "$source_certificate" ]]; then
      printf '[ERROR] 证书路径必须是已存在的绝对路径，请重新输入。\n' >&2
      continue
    fi
    prompt_value source_key "已有私钥 PEM 绝对路径"
    if [[ "$source_key" != /* || ! -f "$source_key" ]]; then
      printf '[ERROR] 私钥路径必须是已存在的绝对路径，请重新输入。\n' >&2
      continue
    fi
    if certificate_is_usable "$source_certificate" "$source_key"; then break; fi
    printf '[ERROR] 证书已过期、未同时覆盖 Reality 和 CDN 域名，或与私钥不匹配。\n' >&2
  done
  install -m 600 "$source_certificate" "$CERT_FILE"
  install -m 600 "$source_key" "$KEY_FILE"
  log "using the supplied certificate and private key"
}

ensure_acme() {
  log "installing official acme.sh stable release ${ACME_VERSION}"
  local installer
  installer="$(mktemp)"
  write_install_state
  if ! curl -fsSL --retry 2 --max-time 30 "$ACME_INSTALL_URL" -o "$installer"; then
    rm -f "$installer"
    die "could not download the official acme.sh installer"
  fi
  if ! BRANCH="$ACME_VERSION" sh "$installer"; then
    rm -f "$installer"
    die "official acme.sh installer failed"
  fi
  rm -f "$installer"
  ACME_BIN="$ACME_HOME/acme.sh"
  [[ -x "$ACME_BIN" ]] || die "acme.sh installation failed"
  ACME_VERSION_INSTALLED="$("$ACME_BIN" --version 2>/dev/null | sed -n '$p')"
}

prepare_certificate() {
  if (( DRY_RUN )); then
    printf '%s\n' 'dry-run certificate' > "$CERT_FILE"
    printf '%s\n' 'dry-run private key' > "$KEY_FILE"
    chmod 600 "$CERT_FILE" "$KEY_FILE"
    return 0
  fi

  if certificate_is_usable "$CERT_FILE" "$KEY_FILE"; then
    if prompt_yes_no "是否替换当前源站证书？"; then
      install_existing_certificate
      return 0
    fi
    log "reusing the managed certificate for $CDN_DOMAIN"
    return 0
  fi

  printf '\nTLS certificate is required for Cloudflare Full (strict).\n'
  if prompt_yes_no "是否已有同时覆盖两个域名的可用 TLS 证书？"; then
    install_existing_certificate
    return 0
  fi

  if [[ -e "${ACME_HOME}/${REALITY_DOMAIN}_ecc" || \
        -e "${ACME_HOME}/${REALITY_DOMAIN}_ecc.conf" || \
        -e "${ACME_HOME}/${REALITY_DOMAIN}.conf" ]]; then
    die "an ACME certificate lineage for ${REALITY_DOMAIN} already exists; provide a certificate file instead of replacing it"
  fi

  local cf_token=""
  if [[ -f "$ACME_HOME/account.conf" ]] && grep -q '^CF_Token=' "$ACME_HOME/account.conf"; then
    log "using the existing Cloudflare DNS API token saved by acme.sh"
  else
    while :; do
      prompt_value cf_token "Cloudflare API Token（Zone DNS Edit + Zone Read；输入可见）"
      if [[ -n "$cf_token" ]]; then break; fi
      printf '[ERROR] Cloudflare API Token 不能为空，请重新输入。\n' >&2
    done
  fi

  ensure_acme
  ACME_DOMAIN="$REALITY_DOMAIN"
  ACME_CERT_ISSUED_BY_TOOL=1
  write_install_state
  "$ACME_BIN" --set-default-ca --server letsencrypt
  local issue_output
  if [[ -n "$cf_token" ]]; then
    issue_output="$(CF_Token="$cf_token" "$ACME_BIN" --issue --dns dns_cf -d "$REALITY_DOMAIN" -d "$CDN_DOMAIN" --keylength ec-256 2>&1)" || {
      printf '%s\n' "${issue_output//"$cf_token"/[REDACTED]}" >&2
      die "acme.sh could not issue a certificate using Cloudflare DNS-01"
    }
  else
    issue_output="$("$ACME_BIN" --issue --dns dns_cf -d "$REALITY_DOMAIN" -d "$CDN_DOMAIN" --keylength ec-256 2>&1)" || {
      printf '%s\n' "$issue_output" >&2
      die "acme.sh could not issue a certificate using the saved Cloudflare token"
    }
  fi
  if [[ -n "$cf_token" ]]; then
    printf '%s\n' "${issue_output//"$cf_token"/[REDACTED]}"
  else
    printf '%s\n' "$issue_output"
  fi
  "$ACME_BIN" --install-cert -d "$REALITY_DOMAIN" --ecc \
    --key-file "$KEY_FILE" \
    --fullchain-file "$CERT_FILE" \
    --reloadcmd 'systemctl reload nginx || true'
  certificate_is_usable "$CERT_FILE" "$KEY_FILE" || die "issued certificate validation failed"
}

write_site() {
  [[ -e "$SITE_DIR/index.html" ]] && return 0
  cat > "$SITE_DIR/index.html" <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Welcome</title></head>
<body><h1>Welcome</h1><p>This site is served by the origin.</p></body></html>
EOF
  chmod 644 "$SITE_DIR/index.html"
  SITE_INDEX_CREATED_BY_TOOL=1
  SITE_INDEX_SHA256="$(sha256sum "$SITE_DIR/index.html" | awk '{print $1}')"
  write_install_state
}

render_xray_config() {
  local inbounds inbound port target internal_port uuid
  inbounds='[]'

  target="127.0.0.1:$((DIRECT_PORT + 10000))"
  inbound="$(jq -cn \
    --arg id "${UUIDS[0]}" \
    --argjson port "$DIRECT_PORT" \
    --arg target "$target" \
    --arg reality_domain "$REALITY_DOMAIN" \
    --arg private_key "$REALITY_PRIVATE_KEY" \
    --arg short_id "$REALITY_SHORT_ID" \
    --arg path "$XHTTP_PATH" \
    '{listen:"0.0.0.0", port:$port, protocol:"vless", settings:{clients:[{id:$id, level:0}], decryption:"none"}, streamSettings:{network:"xhttp", security:"reality", realitySettings:{show:false, target:$target, xver:0, serverNames:[$reality_domain], privateKey:$private_key, shortIds:[$short_id]}, xhttpSettings:{host:"", path:$path, mode:"auto"}}, sniffing:{enabled:true, destOverride:["http","tls","quic"], metadataOnly:false, routeOnly:true}}')"
  inbounds="$(jq -cn --argjson all "$inbounds" --argjson one "$inbound" '$all + [$one]')"

  for port in "${CDN_PORTS[@]}"; do
    internal_port=$((port + 10000))
    uuid="$(cdn_uuid_for_port "$port")"
    inbound="$(jq -cn \
      --arg id "$uuid" \
      --argjson port "$internal_port" \
      --arg path "$XHTTP_PATH" \
      '{listen:"127.0.0.1", port:$port, protocol:"vless", settings:{clients:[{id:$id, level:0}], decryption:"none"}, streamSettings:{network:"xhttp", xhttpSettings:{host:"", path:$path, mode:"auto"}}, sniffing:{enabled:true, destOverride:["http","tls","quic"], metadataOnly:false, routeOnly:true}}')"
    inbounds="$(jq -cn --argjson all "$inbounds" --argjson one "$inbound" '$all + [$one]')"
  done

  jq -n \
    --argjson inbounds "$inbounds" \
    '{log:{loglevel:"warning"}, inbounds:$inbounds, outbounds:[{protocol:"freedom",tag:"direct"}]}' \
    > "$XRAY_CONFIG_PATH"
  chmod 600 "$XRAY_CONFIG_PATH"
  XRAY_CONFIG_SHA256="$(sha256sum "$XRAY_CONFIG_PATH" | awk '{print $1}')"
}

configure_xray_config_permissions() {
  local service_user service_group
  (( DRY_RUN )) && return 0

  service_user="$(systemctl show --property=User --value xray 2>/dev/null || true)"
  service_group="$(systemctl show --property=Group --value xray 2>/dev/null || true)"
  service_user="${service_user:-root}"
  if [[ -z "$service_group" ]]; then
    service_group="$(id -gn "$service_user" 2>/dev/null || true)"
  fi
  [[ -n "$service_group" ]] || die "could not determine the Xray service group"
  getent passwd "$service_user" >/dev/null || die "Xray service user does not exist: $service_user"
  getent group "$service_group" >/dev/null || die "Xray service group does not exist: $service_group"

  XRAY_SERVICE_USER="$service_user"
  XRAY_SERVICE_GROUP="$service_group"
  if [[ "$service_user" == root ]]; then
    chown root:root "$XRAY_CONFIG_PATH"
    chmod 600 "$XRAY_CONFIG_PATH"
    XRAY_CONFIG_MODE=600
  else
    chown root:"$service_group" "$XRAY_CONFIG_PATH"
    chmod 640 "$XRAY_CONFIG_PATH"
    XRAY_CONFIG_MODE=640
  fi
  [[ -r "$XRAY_CONFIG_PATH" ]] || die "Xray configuration is not readable by root"
  if [[ "$service_user" != root ]]; then
    command -v runuser >/dev/null 2>&1 || die "runuser is required to validate the Xray service account"
    runuser -u "$service_user" -- test -r "$XRAY_CONFIG_PATH" ||
      die "Xray service user cannot read $XRAY_CONFIG_PATH"
  fi
}

render_nginx_config() {
  local port internal_port http2_listen http2_directive nginx_version
  http2_listen='ssl http2'
  http2_directive=''
  if (( ! DRY_RUN )); then
    nginx_version="$(nginx -v 2>&1 | sed -n 's|.*/||p')"
    if dpkg --compare-versions "$nginx_version" ge 1.25.1; then
      http2_listen='ssl'
      http2_directive='    http2 on;'
    fi
  fi
  : > "$NGINX_CONF_PATH"
  internal_port=$((DIRECT_PORT + 10000))
  cat >> "$NGINX_CONF_PATH" <<EOF
server {
    listen 127.0.0.1:${internal_port} ssl;
    server_name ${REALITY_DOMAIN};

    access_log off;
    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_tickets off;
    client_max_body_size 0;
    client_body_timeout 1h;

    location / {
        root ${SITE_DIR};
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }
}

EOF
  for port in "${CDN_PORTS[@]}"; do
    internal_port=$((port + 10000))
    cat >> "$NGINX_CONF_PATH" <<EOF
server {
    listen ${port} ${http2_listen};
${http2_directive}
    server_name ${CDN_DOMAIN};

    access_log off;
    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_tickets off;
    client_max_body_size 0;
    client_body_timeout 1h;

    location ^~ ${XHTTP_PATH} {
        grpc_pass 127.0.0.1:${internal_port};
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_set_header Host \$host;
        grpc_set_header TE trailers;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        root ${SITE_DIR};
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }
}

EOF
  done
  chmod 644 "$NGINX_CONF_PATH"
  NGINX_CONFIG_SHA256="$(sha256sum "$NGINX_CONF_PATH" | awk '{print $1}')"
}

url_encode() {
  jq -rn --arg value "$1" '$value | @uri'
}

render_client_links() {
  local direct_server encoded_path port extra encoded_extra name xmux uuid default_name
  direct_server="$VPS_IPV4"
  encoded_path="$(url_encode "$XHTTP_PATH")"
  xmux='{"maxConcurrency":"16-32","maxConnections":0,"cMaxReuseTimes":0,"hMaxRequestTimes":"600-900","hMaxReusableSecs":"1800-3000","hKeepAlivePeriod":0}'
  : > "$CLIENT_FILE"

  default_name="xhttp-reality-direct-${DIRECT_PORT}"
  name="${NODE_NAMES[0]:-$default_name}"
  extra="$(jq -cn --argjson xmux "$xmux" '{xmux:$xmux}')"
  encoded_extra="$(url_encode "$extra")"
  printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=xhttp&path=%s&mode=auto&extra=%s#%s\n' \
    "${UUIDS[0]}" "$direct_server" "$DIRECT_PORT" \
    "$(url_encode "$REALITY_DOMAIN")" "$(url_encode "$PUBLIC_KEY")" \
    "$(url_encode "$REALITY_SHORT_ID")" "$encoded_path" "$encoded_extra" "$(url_encode "$name")" >> "$CLIENT_FILE"

  for port in "${CDN_PORTS[@]}"; do
    uuid="$(cdn_uuid_for_port "$port")"
    default_name="xhttp-tls-cdn-${port}"
    name="$(cdn_node_name_for_port "$port")"
    name="${name:-$default_name}"
    extra="$(jq -cn \
      --argjson xmux "$xmux" \
      '{xmux:$xmux}')"
    encoded_extra="$(url_encode "$extra")"
    printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&alpn=h2&type=xhttp&host=%s&path=%s&mode=auto&extra=%s#%s\n' \
      "$uuid" "$CDN_DOMAIN" "$port" \
      "$(url_encode "$CDN_DOMAIN")" "$(url_encode "$CDN_DOMAIN")" \
      "$encoded_path" "$encoded_extra" "$(url_encode "$name")" >> "$CLIENT_FILE"
  done
  chmod 600 "$CLIENT_FILE"
  CLIENT_FILE_SHA256="$(sha256sum "$CLIENT_FILE" | awk '{print $1}')"
}

write_state() {
  local state_file="${STATE_DIR}/config.env"
  local temporary="${state_file}.tmp"
  {
    printf 'REALITY_DOMAIN=%q\n' "$REALITY_DOMAIN"
    printf 'CDN_DOMAIN=%q\n' "$CDN_DOMAIN"
    printf 'DIRECT_PORT=%q\n' "$DIRECT_PORT"
    printf 'VPS_IPV4=%q\n' "$VPS_IPV4"
    printf 'UUID_DIRECT=%q\n' "${UUIDS[0]}"
    printf 'UUID_2053=%q\n' "${UUIDS[1]}"
    printf 'UUID_2083=%q\n' "${UUIDS[2]}"
    printf 'UUID_2087=%q\n' "${UUIDS[3]}"
    printf 'UUID_2096=%q\n' "${UUIDS[4]}"
    printf 'REALITY_PRIVATE_KEY=%q\n' "$REALITY_PRIVATE_KEY"
    printf 'REALITY_PUBLIC_KEY=%q\n' "$PUBLIC_KEY"
    printf 'REALITY_SHORT_ID=%q\n' "$REALITY_SHORT_ID"
    printf 'XHTTP_PATH=%q\n' "$XHTTP_PATH"
    printf 'NODE_ALIAS_BASE=%q\n' "$NODE_ALIAS_BASE"
    printf 'CDN_PORTS_ACTIVE=%q\n' "$(ports_as_space_list "${CDN_PORTS[@]}")"
    printf 'CDN_PORTS_SKIPPED=%q\n' "$(ports_as_space_list "${SKIPPED_CDN_PORTS[@]}")"
    for port in "${SKIPPED_CDN_PORTS[@]}"; do
      printf 'CDN_SKIP_REASON_%s=%q\n' "$port" "${CDN_SKIP_REASONS[$port]}"
    done
    printf 'NODE_NAME_DIRECT=%q\n' "${NODE_NAMES[0]}"
    printf 'NODE_NAME_2053=%q\n' "${NODE_NAMES[1]}"
    printf 'NODE_NAME_2083=%q\n' "${NODE_NAMES[2]}"
    printf 'NODE_NAME_2087=%q\n' "${NODE_NAMES[3]}"
    printf 'NODE_NAME_2096=%q\n' "${NODE_NAMES[4]}"
    printf 'CERT_FILE=%q\n' "$CERT_FILE"
    printf 'KEY_FILE=%q\n' "$KEY_FILE"
  } > "$temporary"
  chmod 600 "$temporary"
  mv -f "$temporary" "$state_file"
}

validate_nginx_config_loaded() {
  local nginx_dump
  nginx_dump="$(nginx -T 2>&1)" || {
    printf '[ERROR] Nginx configuration dump failed; existing Nginx/OpenResty configuration is not usable.\n%s\n' \
      "$nginx_dump" >&2
    return 1
  }
  if [[ "$nginx_dump" != *"configuration file ${NGINX_CONF_PATH}"* ]]; then
    printf '[ERROR] the active Nginx configuration does not load %s\n' "$NGINX_CONF_PATH" >&2
    return 1
  fi
}

validate_services() {
  (( DRY_RUN )) && return 0
  nginx -t
  validate_nginx_config_loaded || die "the active Nginx service does not load the tool configuration"
  /usr/local/bin/xray run -test -config "$XRAY_CONFIG_PATH"
  if [[ "$XRAY_SERVICE_USER" != root ]]; then
    runuser -u "$XRAY_SERVICE_USER" -- /usr/local/bin/xray run -test -config "$XRAY_CONFIG_PATH" ||
      die "Xray configuration cannot be parsed by the service account"
  fi
}

report_service_failure() {
  local service="$1"
  printf '[ERROR] %s service diagnostics:\n' "$service" >&2
  systemctl status "$service" --no-pager -l >&2 || true
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -u "$service" -b -n 50 --no-pager >&2 || true
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp >&2 || true
  fi
}

start_services() {
  (( DRY_RUN )) && return 0
  systemctl daemon-reload
  if ! systemctl enable nginx >/dev/null; then
    report_service_failure nginx
    die "could not enable nginx.service"
  fi
  if ! systemctl enable xray >/dev/null; then
    report_service_failure xray
    die "could not enable xray.service"
  fi
  if ! systemctl restart nginx; then
    report_service_failure nginx
    die "nginx failed to restart; check existing Nginx/OpenResty/Nginx Proxy Manager port ownership"
  fi
  if ! systemctl restart xray; then
    report_service_failure xray
    die "xray failed to restart"
  fi
  if ! systemctl is-active --quiet nginx; then
    report_service_failure nginx
    die "nginx did not become active"
  fi
  if ! systemctl is-active --quiet xray; then
    report_service_failure xray
    die "xray did not become active"
  fi
}

print_summary() {
  local active_ports
  active_ports="$(ports_as_space_list "${CDN_PORTS[@]}")"
  active_ports="${active_ports:-无}"
  printf '\n部署完成。\n'
  printf '客户端链接：%s\n' "$CLIENT_FILE"
  printf 'Xray 配置： %s\n' "$XRAY_CONFIG_PATH"
  printf '状态文件：  %s\n' "${STATE_DIR}/config.env"
  printf '\n请在 VPS / 云厂商防火墙放行 TCP 入站端口：%s %s\n' "$active_ports" "$DIRECT_PORT"
  printf 'Cloudflare CDN 域名：%s（橙云，实际端口 %s）\n' "$CDN_DOMAIN" "$active_ports"
  printf '双向直连 Reality：TCP %s，SNI %s\n' "$DIRECT_PORT" "$REALITY_DOMAIN"
  printf '双向经 CDN：TCP %s（域名 %s）\n' "$active_ports" "$CDN_DOMAIN"
  for port in "${SKIPPED_CDN_PORTS[@]}"; do
    printf '已跳过 CDN 端口 %s：%s。\n' "$port" "${CDN_SKIP_REASONS[$port]}"
  done
  printf '\n'
  cat "$CLIENT_FILE"
}

main() {
  parse_args "$@"
  init_paths
  require_debian_root
  open_prompt_fd
  if (( ! DRY_RUN )); then
    require_fresh_xray
  fi
  collect_inputs

  if (( ! DRY_RUN )); then
    initialize_install_state
    install_packages
    resolve_latest_versions || die "could not resolve latest official component versions"
    install_xray
  fi

  derive_public_key
  ensure_state_dirs
  prepare_certificate
  if (( ! DRY_RUN )) && [[ -x "$ACME_HOME/acme.sh" ]] && [[ "$ACME_VERSION_INSTALLED" == unavailable ]]; then
    ACME_VERSION_INSTALLED="$("$ACME_HOME/acme.sh" --version 2>/dev/null | sed -n '$p')"
  fi
  if (( ! DRY_RUN )); then
    check_reality_ports || die "Reality 直连端口检查失败"
    select_cdn_ports
  fi
  write_site
  render_xray_config
  configure_xray_config_permissions
  render_nginx_config
  render_client_links
  if (( ! DRY_RUN )); then
    NGINX_VERSION_INSTALLED="$(nginx -v 2>&1)"
    DEBIAN_PACKAGE_VERSIONS="$(dpkg-query -W -f='${binary:Package}=${Version}\n' "${DEBIAN_PACKAGES[@]}" | sort)"
    COMPONENTS_UPDATED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  write_state
  write_install_state
  validate_services
  start_services
  print_summary
}

if [[ "${XHTTP_LIBRARY_MODE:-0}" != 1 ]]; then
  main "$@"
fi
