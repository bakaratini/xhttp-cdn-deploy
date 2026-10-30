#!/usr/bin/env bash
export XHTTP_XRAY_VERSION=v26.10.29
export XHTTP_XRAY_INSTALL_REF=e42df6a772e60dd7b058f852262c4dbeb0bc231d
export XHTTP_ACME_VERSION=3.1.6
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP_NAME="xhttp-cdn-deploy"
DEFAULT_SHORT_ID="a1234567"
DEFAULT_XHTTP_PATH="/xhttp"
INTERNAL_XHTTP_PORT=18080
PORTS=(2053 2083 2087 2096)
ACME_INSTALL_URL="https://get.acme.sh"
XRAY_INSTALL_REF="${XHTTP_XRAY_INSTALL_REF:-main}"
XRAY_VERSION="${XHTTP_XRAY_VERSION:-latest}"
ACME_VERSION="${XHTTP_ACME_VERSION:-latest}"

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
    read -r -u "$PROMPT_FD" -p "$message [$default_value]: " answer
    answer="${answer:-$default_value}"
  else
    read -r -u "$PROMPT_FD" -p "$message: " answer
  fi
  printf -v "$variable" '%s' "$answer"
}

prompt_secret() {
  local variable="$1"
  local message="$2"
  local answer
  read -r -s -u "$PROMPT_FD" -p "$message: " answer
  printf '\n' >&2
  printf -v "$variable" '%s' "$answer"
}

prompt_yes_no() {
  local message="$1"
  local default_value="${2:-N}"
  local answer
  read -r -u "$PROMPT_FD" -p "$message [y/N]: " answer
  answer="${answer:-$default_value}"
  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
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

collect_inputs() {
  local detected_ip
  REALITY_DOMAIN=""
  CDN_DOMAIN=""

  printf '\n%s\n' "${APP_NAME}: four XHTTP + Reality/CDN nodes"
  printf '%s\n' "Reality 域名必须是你控制的灰云子域名；证书将同时覆盖它和 CDN 域名。"
  prompt_value REALITY_DOMAIN "Reality 灰云域名 / SNI"
  prompt_value CDN_DOMAIN "Cloudflare 橙云 CDN 域名"
  REALITY_DOMAIN="${REALITY_DOMAIN,,}"
  CDN_DOMAIN="${CDN_DOMAIN,,}"
  valid_domain "$REALITY_DOMAIN" || die "invalid Reality domain"
  valid_domain "$CDN_DOMAIN" || die "invalid CDN domain"
  [[ "$REALITY_DOMAIN" != "$CDN_DOMAIN" ]] || die "Reality and CDN domains must be different"

  detected_ip="$(detect_ipv4)"
  prompt_value VPS_IPV4 "VPS 公网 IPv4" "$detected_ip"
  valid_ipv4 "$VPS_IPV4" || die "invalid IPv4 address"

  UUIDS=()
  local index value
  for index in 1 2 3 4; do
    value=""
    prompt_value value "第 ${index} 个节点 UUID"
    valid_uuid "$value" || die "invalid UUID for node ${index}"
    local previous
    for previous in "${UUIDS[@]}"; do
      [[ "${previous,,}" != "${value,,}" ]] || die "each node must use a different UUID"
    done
    UUIDS+=("$value")
  done

  REALITY_PRIVATE_KEY=""
  prompt_secret REALITY_PRIVATE_KEY "Reality 私钥（base64url）"
  [[ -n "$REALITY_PRIVATE_KEY" ]] || die "Reality private key cannot be empty"

  REALITY_SHORT_ID=""
  prompt_value REALITY_SHORT_ID "Reality Short ID" "$DEFAULT_SHORT_ID"
  valid_short_id "$REALITY_SHORT_ID" ||
    die "Short ID must be 2-16 hexadecimal characters with an even length"

  XHTTP_PATH=""
  prompt_value XHTTP_PATH "XHTTP 路径" "$DEFAULT_XHTTP_PATH"
  valid_xhttp_path "$XHTTP_PATH" || die "invalid XHTTP path"
}

install_packages() {
  (( DRY_RUN )) && return 0
  log "installing Debian dependencies"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl cron jq nginx openssl unzip
}

install_xray() {
  (( DRY_RUN )) && return 0
  log "installing official Xray-core ${XRAY_VERSION}"
  local installer
  installer="$(mktemp)"
  curl -fsSL "https://raw.githubusercontent.com/XTLS/Xray-install/${XRAY_INSTALL_REF}/install-release.sh" -o "$installer"
  if [[ "$XRAY_VERSION" == latest ]]; then
    bash "$installer" install -u root
  else
    bash "$installer" install -u root --version "$XRAY_VERSION"
  fi
  rm -f "$installer"
  [[ -x /usr/local/bin/xray ]] || die "Xray installation did not produce /usr/local/bin/xray"
}

derive_public_key() {
  if (( DRY_RUN )); then
    PUBLIC_KEY="${XHTTP_TEST_PUBLIC_KEY:-test-public-key}"
    return 0
  fi

  local output
  output="$(/usr/local/bin/xray x25519 -i "$REALITY_PRIVATE_KEY" 2>&1)" ||
    die "Xray rejected the Reality private key"
  PUBLIC_KEY="$(awk -F': *' 'tolower($1) ~ /publickey/ { print $2; exit }' <<< "$output")"
  [[ -n "$PUBLIC_KEY" ]] || die "could not derive the Reality public key from the private key"
}

ensure_state_dirs() {
  install -d -m 700 "$STATE_DIR" "$CERT_DIR" "$CLIENT_DIR"
  install -d -m 755 "$SITE_DIR"
  install -d -m 700 "$STATE_DIR/backups"
  if (( ! DRY_RUN )); then
    install -d -m 755 "$(dirname "$XRAY_CONFIG_PATH")" "$(dirname "$NGINX_CONF_PATH")"
    backup_file "$XRAY_CONFIG_PATH"
    backup_file "$NGINX_CONF_PATH"
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
  source_certificate=""
  source_key=""
  prompt_value source_certificate "已有证书 PEM 绝对路径"
  prompt_value source_key "已有私钥 PEM 绝对路径"
  [[ "$source_certificate" == /* && -f "$source_certificate" ]] ||
    die "certificate path must be an existing absolute path"
  [[ "$source_key" == /* && -f "$source_key" ]] ||
    die "private key path must be an existing absolute path"
  certificate_is_usable "$source_certificate" "$source_key" ||
    die "证书已过期、未同时覆盖 Reality 和 CDN 域名，或与私钥不匹配"
  install -m 600 "$source_certificate" "$CERT_FILE"
  install -m 600 "$source_key" "$KEY_FILE"
  log "using the supplied certificate and private key"
}

ensure_acme() {
  if [[ "$ACME_VERSION" == latest ]] && command -v acme.sh >/dev/null 2>&1; then
    ACME_BIN="$(command -v acme.sh)"
    return 0
  fi
  if [[ "$ACME_VERSION" != latest && -x "$ACME_HOME/acme.sh" ]] &&
     "$ACME_HOME/acme.sh" --version 2>/dev/null | grep -Fq "$ACME_VERSION"; then
    ACME_BIN="$ACME_HOME/acme.sh"
    return 0
  fi
  log "installing official acme.sh ${ACME_VERSION}"
  local installer
  installer="$(mktemp)"
  curl -fsSL "$ACME_INSTALL_URL" -o "$installer"
  if [[ "$ACME_VERSION" == latest ]]; then
    sh "$installer"
  else
    BRANCH="$ACME_VERSION" sh "$installer"
  fi
  rm -f "$installer"
  ACME_BIN="$ACME_HOME/acme.sh"
  [[ -x "$ACME_BIN" ]] || ACME_BIN="$(command -v acme.sh || true)"
  [[ -n "$ACME_BIN" ]] || die "acme.sh installation failed"
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

  local cf_token=""
  if [[ -f "$ACME_HOME/account.conf" ]] && grep -q '^CF_Token=' "$ACME_HOME/account.conf"; then
    log "using the existing Cloudflare DNS API token saved by acme.sh"
  else
    prompt_secret cf_token "Cloudflare API Token（Zone DNS Edit + Zone Read）"
    [[ -n "$cf_token" ]] || die "Cloudflare API Token cannot be empty"
  fi

  ensure_acme
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

backup_file() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  local name timestamp
  name="$(basename "$path")"
  timestamp="$(date -u +%Y%m%dT%H%M%S).$$.${RANDOM}"
  cp -a "$path" "$STATE_DIR/backups/${name}.${timestamp}"
}

write_site() {
  [[ -e "$SITE_DIR/index.html" ]] && return 0
  cat > "$SITE_DIR/index.html" <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Welcome</title></head>
<body><h1>Welcome</h1><p>This site is served by the origin.</p></body></html>
EOF
  chmod 644 "$SITE_DIR/index.html"
}

build_internal_clients_json() {
  printf '%s\n' "${UUIDS[@]}" | jq -Rsc 'split("\n")[:-1] | map({id: ., level: 0})'
}

render_xray_config() {
  local internal_clients inbounds inbound port target index
  internal_clients="$(build_internal_clients_json)"
  inbounds='[]'

  for index in 0 1 2 3; do
    port="${PORTS[$index]}"
    target="127.0.0.1:$((port + 10000))"
    inbound="$(jq -cn \
      --argjson clients "$(jq -n --arg id "${UUIDS[$index]}" '[{id: $id, level: 0}]')" \
      --argjson port "$port" \
      --arg target "$target" \
      --arg reality_domain "$REALITY_DOMAIN" \
      --arg private_key "$REALITY_PRIVATE_KEY" \
      --arg short_id "$REALITY_SHORT_ID" \
      --arg path "$XHTTP_PATH" \
      '{listen:"0.0.0.0", port:$port, protocol:"vless", settings:{clients:$clients, decryption:"none"}, streamSettings:{network:"xhttp", security:"reality", realitySettings:{show:false, target:$target, xver:0, serverNames:[$reality_domain], privateKey:$private_key, shortIds:[$short_id]}, xhttpSettings:{host:"", path:$path, mode:"auto"}}, sniffing:{enabled:true, destOverride:["http","tls","quic"], metadataOnly:false, routeOnly:true}}')"
    inbounds="$(jq -cn --argjson all "$inbounds" --argjson one "$inbound" '$all + [$one]')"
  done

  inbound="$(jq -cn \
    --argjson clients "$internal_clients" \
    --argjson port "$INTERNAL_XHTTP_PORT" \
    --arg path "$XHTTP_PATH" \
    '{listen:"127.0.0.1", port:$port, protocol:"vless", settings:{clients:$clients, decryption:"none"}, streamSettings:{network:"xhttp", xhttpSettings:{host:"", path:$path, mode:"auto"}}, sniffing:{enabled:true, destOverride:["http","tls","quic"], metadataOnly:false, routeOnly:true}}')"
  inbounds="$(jq -cn --argjson all "$inbounds" --argjson one "$inbound" '$all + [$one]')"

  jq -n \
    --argjson inbounds "$inbounds" \
    '{log:{loglevel:"warning"}, inbounds:$inbounds, outbounds:[{protocol:"freedom",tag:"direct"}]}' \
    > "$XRAY_CONFIG_PATH"
  chmod 600 "$XRAY_CONFIG_PATH"
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
  for port in "${PORTS[@]}"; do
    internal_port=$((port + 10000))
    cat >> "$NGINX_CONF_PATH" <<EOF
server {
    listen 127.0.0.1:${internal_port} ${http2_listen};
${http2_directive}
    server_name ${REALITY_DOMAIN} ${CDN_DOMAIN};

    access_log off;
    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_tickets off;
    client_max_body_size 0;
    client_body_timeout 1h;

    location ^~ ${XHTTP_PATH} {
        grpc_pass 127.0.0.1:${INTERNAL_XHTTP_PORT};
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
}

url_encode() {
  jq -rn --arg value "$1" '$value | @uri'
}

render_client_links() {
  local direct_server encoded_path port index extra encoded_extra name xmux
  direct_server="$VPS_IPV4"
  encoded_path="$(url_encode "$XHTTP_PATH")"
  xmux='{"maxConcurrency":"16-32","maxConnections":0,"cMaxReuseTimes":0,"hMaxRequestTimes":"600-900","hMaxReusableSecs":"1800-3000","hKeepAlivePeriod":0}'
  : > "$CLIENT_FILE"

  for index in 0 1 2 3; do
    port="${PORTS[$index]}"
    if [[ "$port" == "2053" ]]; then
      name="xhttp-reality-direct-2053"
      extra="$(jq -cn --argjson xmux "$xmux" '{xmux:$xmux}')"
      encoded_extra="$(url_encode "$extra")"
      printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=xhttp&path=%s&mode=auto&extra=%s#%s\n' \
        "${UUIDS[$index]}" "$direct_server" "$port" \
        "$(url_encode "$REALITY_DOMAIN")" "$(url_encode "$PUBLIC_KEY")" \
        "$(url_encode "$REALITY_SHORT_ID")" "$encoded_path" "$encoded_extra" "$name" >> "$CLIENT_FILE"
      continue
    fi

    name="xhttp-reality-upload-cdn-download-${port}"
    extra="$(jq -cn \
      --arg address "$CDN_DOMAIN" \
      --argjson port "$port" \
      --arg path "$XHTTP_PATH" \
      --argjson xmux "$xmux" \
      '{xmux:$xmux,downloadSettings:{address:$address,port:$port,network:"xhttp",security:"tls",tlsSettings:{serverName:$address,allowInsecure:false,alpn:["h2"],fingerprint:"chrome"},xhttpSettings:{host:$address,path:$path,mode:"auto",xmux:$xmux}}}')"
    encoded_extra="$(url_encode "$extra")"
    printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=xhttp&path=%s&mode=auto&extra=%s#%s\n' \
      "${UUIDS[$index]}" "$direct_server" "$port" \
      "$(url_encode "$REALITY_DOMAIN")" "$(url_encode "$PUBLIC_KEY")" \
      "$(url_encode "$REALITY_SHORT_ID")" "$encoded_path" "$encoded_extra" "$name" >> "$CLIENT_FILE"
  done
  chmod 600 "$CLIENT_FILE"
}

write_state() {
  local state_file="${STATE_DIR}/config.env"
  local temporary="${state_file}.tmp"
  {
    printf 'REALITY_DOMAIN=%q\n' "$REALITY_DOMAIN"
    printf 'CDN_DOMAIN=%q\n' "$CDN_DOMAIN"
    printf 'VPS_IPV4=%q\n' "$VPS_IPV4"
    printf 'UUID_2053=%q\n' "${UUIDS[0]}"
    printf 'UUID_2083=%q\n' "${UUIDS[1]}"
    printf 'UUID_2087=%q\n' "${UUIDS[2]}"
    printf 'UUID_2096=%q\n' "${UUIDS[3]}"
    printf 'REALITY_PRIVATE_KEY=%q\n' "$REALITY_PRIVATE_KEY"
    printf 'REALITY_PUBLIC_KEY=%q\n' "$PUBLIC_KEY"
    printf 'REALITY_SHORT_ID=%q\n' "$REALITY_SHORT_ID"
    printf 'XHTTP_PATH=%q\n' "$XHTTP_PATH"
    printf 'CERT_FILE=%q\n' "$CERT_FILE"
    printf 'KEY_FILE=%q\n' "$KEY_FILE"
    printf 'XRAY_VERSION=%q\n' "$(if (( DRY_RUN )); then printf '%s' dry-run; else /usr/local/bin/xray version 2>/dev/null | head -n1; fi)"
    printf 'XRAY_VERSION_REQUESTED=%q\n' "$XRAY_VERSION"
    printf 'NGINX_VERSION=%q\n' "$(if (( DRY_RUN )); then printf '%s' dry-run; else nginx -v 2>&1; fi)"
    printf 'ACME_VERSION=%q\n' "$(if (( DRY_RUN )); then printf '%s' dry-run; elif [[ -x "$ACME_HOME/acme.sh" ]]; then "$ACME_HOME/acme.sh" --version 2>/dev/null | head -n1; else printf '%s' unavailable; fi)"
  } > "$temporary"
  chmod 600 "$temporary"
  mv -f "$temporary" "$state_file"
}

validate_services() {
  (( DRY_RUN )) && return 0
  nginx -t
  /usr/local/bin/xray run -test -config "$XRAY_CONFIG_PATH"
}

start_services() {
  (( DRY_RUN )) && return 0
  systemctl daemon-reload
  systemctl enable nginx >/dev/null
  systemctl enable xray >/dev/null
  systemctl restart nginx
  systemctl restart xray
  systemctl is-active --quiet nginx || die "nginx did not become active"
  systemctl is-active --quiet xray || die "xray did not become active"
}

print_summary() {
  printf '\n部署完成。\n'
  printf '客户端链接：%s\n' "$CLIENT_FILE"
  printf 'Xray 配置： %s\n' "$XRAY_CONFIG_PATH"
  printf '状态文件：  %s\n' "${STATE_DIR}/config.env"
  printf '\n请在 VPS / 云厂商防火墙放行 TCP 入站端口：%s\n' "${PORTS[*]}"
  printf 'Cloudflare CDN 域名：%s（橙云，端口 2083/2087/2096）\n' "$CDN_DOMAIN"
  printf 'Reality SNI：%s\n\n' "$REALITY_DOMAIN"
  cat "$CLIENT_FILE"
}

main() {
  parse_args "$@"
  init_paths
  require_debian_root
  open_prompt_fd

  if (( ! DRY_RUN )); then
    install_packages
    install_xray
  fi

  collect_inputs
  derive_public_key
  ensure_state_dirs
  prepare_certificate
  write_site
  render_xray_config
  render_nginx_config
  render_client_links
  write_state
  validate_services
  start_services
  print_summary
}

if [[ "${XHTTP_LIBRARY_MODE:-0}" != 1 ]]; then
  main "$@"
fi
