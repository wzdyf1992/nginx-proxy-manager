#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="0.1.0"

BASE_DIR="${NPMGR_BASE_DIR:-/etc/nginx-proxy-manager}"
RULES_DIR="$BASE_DIR/rules"
CERTS_DIR="$BASE_DIR/certs"
RUNTIME_DIR="$BASE_DIR/runtime"
NPMGR_NGINX_ETC="${NPMGR_NGINX_ETC:-/etc/nginx}"
SITES_AVAILABLE_DIR="$NPMGR_NGINX_ETC/sites-available"
SITES_ENABLED_DIR="$NPMGR_NGINX_ETC/sites-enabled"
STREAMS_AVAILABLE_DIR="$NPMGR_NGINX_ETC/streams-available"
STREAMS_ENABLED_DIR="$NPMGR_NGINX_ETC/streams-enabled"
NPMGR_ACME_HOME="${NPMGR_ACME_HOME:-$HOME/.acme.sh}"
NPMGR_CF_CONFIG="${NPMGR_CF_CONFIG:-$BASE_DIR/cloudflare.conf}"
NPMGR_SYSTEMCTL_BIN="${NPMGR_SYSTEMCTL_BIN:-systemctl}"
NPMGR_APT_GET_BIN="${NPMGR_APT_GET_BIN:-apt-get}"
NPMGR_TEST_MODE="${NPMGR_TEST_MODE:-0}"
NPMGR_ACME_SERVER="${NPMGR_ACME_SERVER:-letsencrypt}"
ACME_LOG_FILE="$RUNTIME_DIR/acme.sh.log"

log() {
  printf '提示：%s\n' "$*"
}

warn() {
  printf '警告：%s\n' "$*" >&2
}

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  if [[ "$NPMGR_TEST_MODE" == "1" ]]; then
    return
  fi
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请用 root 运行此脚本。"
}

require_command() {
  local name="$1"
  command_exists "$name" || die "缺少依赖命令: $name"
}

ensure_directory() {
  mkdir -p "$1"
}

write_file() {
  local path="$1"
  local content="$2"
  local parent
  parent="$(dirname "$path")"
  mkdir -p "$parent"
  printf '%s' "$content" >"$path"
}

load_cloudflare_credentials() {
  if [[ -f "$NPMGR_CF_CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$NPMGR_CF_CONFIG"
  fi
}

safe_symlink() {
  local target="$1"
  local link_path="$2"
  mkdir -p "$(dirname "$link_path")"
  ln -sfn "$target" "$link_path"
}

bool_normalize() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    1|true|yes|on|enabled) printf 'on' ;;
    0|false|no|off|disabled|'') printf 'off' ;;
    *) die "无效布尔值: $1" ;;
  esac
}

is_valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 ))
}

is_valid_rule_name() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

is_valid_domain() {
  local domain="$1"
  [[ -n "$domain" ]] || return 1
  [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

is_valid_ipv4() {
  local ip="$1"
  local part
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a parts <<<"$ip"
  for part in "${parts[@]}"; do
    (( part >= 0 && part <= 255 )) || return 1
  done
}

is_valid_hostname() {
  local host="$1"
  [[ "$host" =~ ^[A-Za-z0-9._-]+$ ]]
}

validate_upstream_host() {
  local host="$1"
  if is_valid_ipv4 "$host" || is_valid_hostname "$host"; then
    return 0
  fi
  die "无效上游地址: $host"
}

validate_rule_name() {
  local rule_name="$1"
  is_valid_rule_name "$rule_name" || die "规则名只能包含字母、数字、点、下划线、短横线。"
}

validate_port() {
  local port="$1"
  is_valid_port "$port" || die "端口无效: $port"
}

validate_http_rule() {
  validate_rule_name "$RULE_NAME"
  validate_port "$LISTEN_PORT"
  validate_upstream_host "$UPSTREAM_HOST"
  validate_port "$UPSTREAM_PORT"
  [[ "$UPSTREAM_PROTO" == "http" || "$UPSTREAM_PROTO" == "https" ]] || die "上游协议只能是 http 或 https。"
  [[ "$ENABLE_HTTPS" == "on" || "$ENABLE_HTTPS" == "off" ]] || die "HTTPS 开关只能填写 on 或 off。"
  [[ "$AUTO_DNS" == "on" || "$AUTO_DNS" == "off" ]] || die "自动 DNS 开关只能填写 on 或 off。"
  if [[ -n "${SERVER_NAME:-}" ]]; then
    is_valid_domain "$SERVER_NAME" || die "域名无效: $SERVER_NAME"
  fi
  if [[ "$ENABLE_HTTPS" == "on" && -z "${SERVER_NAME:-}" ]]; then
    die "启用 HTTPS 时必须提供域名。"
  fi
}

validate_tcp_rule() {
  validate_rule_name "$RULE_NAME"
  validate_port "$LISTEN_PORT"
  validate_upstream_host "$UPSTREAM_HOST"
  validate_port "$UPSTREAM_PORT"
  [[ "$TLS_MODE" == "passthrough" || "$TLS_MODE" == "terminate" ]] || die "TLS 模式只能是 passthrough 或 terminate。"
  if [[ "$TLS_MODE" == "terminate" ]]; then
    [[ -n "${SERVER_NAME:-}" ]] || die "TCP TLS 终止模式必须提供域名。"
    is_valid_domain "$SERVER_NAME" || die "域名无效: $SERVER_NAME"
  fi
}

load_rule() {
  local rule_name="$1"
  local path="$RULES_DIR/$rule_name.conf"
  [[ -f "$path" ]] || die "规则不存在: $rule_name"
  # shellcheck disable=SC1090
  source "$path"
}

save_rule_file() {
  local path="$1"
  shift
  local content="$*"
  write_file "$path" "$content"
}

build_http_rule_content() {
  cat <<EOF
RULE_NAME=$RULE_NAME
RULE_TYPE=http
SERVER_NAME=${SERVER_NAME:-}
LISTEN_PORT=$LISTEN_PORT
UPSTREAM_HOST=$UPSTREAM_HOST
UPSTREAM_PORT=$UPSTREAM_PORT
UPSTREAM_PROTO=$UPSTREAM_PROTO
ENABLE_HTTPS=$ENABLE_HTTPS
AUTO_DNS=$AUTO_DNS
CF_ZONE=${CF_ZONE:-}
CF_RECORD_NAME=${CF_RECORD_NAME:-}
CERT_MODE=${CERT_MODE:-dns_cf}
ENABLED=${ENABLED:-on}
EOF
}

build_tcp_rule_content() {
  cat <<EOF
RULE_NAME=$RULE_NAME
RULE_TYPE=tcp
LISTEN_PORT=$LISTEN_PORT
UPSTREAM_HOST=$UPSTREAM_HOST
UPSTREAM_PORT=$UPSTREAM_PORT
TLS_MODE=$TLS_MODE
SERVER_NAME=${SERVER_NAME:-}
CERT_MODE=${CERT_MODE:-dns_cf}
ENABLED=${ENABLED:-on}
EOF
}

build_http_nginx_config() {
  local redirect_block=''
  local tls_block=''
  local server_name_line='_'
  local listen_options=''
  local upstream="${UPSTREAM_PROTO}://${UPSTREAM_HOST}:${UPSTREAM_PORT}"

  if [[ -n "${SERVER_NAME:-}" ]]; then
    server_name_line="$SERVER_NAME"
  fi

  if [[ "$ENABLE_HTTPS" == "on" ]]; then
    local cert_dir="$CERTS_DIR/$SERVER_NAME"
    listen_options=' ssl'
    tls_block=$(cat <<EOF
    ssl_certificate ${cert_dir}/fullchain.pem;
    ssl_certificate_key ${cert_dir}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
EOF
)
    redirect_block=$(cat <<EOF
server {
    listen 80;
    server_name $server_name_line;
    return 301 https://\$host\$request_uri;
}

EOF
)
  fi

  cat <<EOF
${redirect_block}server {
    listen ${LISTEN_PORT}${listen_options};
    server_name ${server_name_line};
${tls_block}
    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_pass ${upstream};
    }
}
EOF
}

build_tcp_nginx_config() {
  if [[ "$TLS_MODE" == "terminate" ]]; then
    local cert_dir="$CERTS_DIR/$SERVER_NAME"
    cat <<EOF
server {
    listen ${LISTEN_PORT} ssl;
    proxy_pass ${UPSTREAM_HOST}:${UPSTREAM_PORT};
    ssl_certificate ${cert_dir}/fullchain.pem;
    ssl_certificate_key ${cert_dir}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
}
EOF
  else
    cat <<EOF
server {
    listen ${LISTEN_PORT};
    proxy_pass ${UPSTREAM_HOST}:${UPSTREAM_PORT};
}
EOF
  fi
}

render_http_rule() {
  local available_path="$SITES_AVAILABLE_DIR/npmgr-$RULE_NAME.conf"
  local enabled_path="$SITES_ENABLED_DIR/npmgr-$RULE_NAME.conf"
  local tmp_path="${available_path}.tmp"
  build_http_nginx_config >"$tmp_path"
  mv "$tmp_path" "$available_path"
  safe_symlink "$available_path" "$enabled_path"
}

render_tcp_rule() {
  ensure_stream_support
  local available_path="$STREAMS_AVAILABLE_DIR/npmgr-$RULE_NAME.conf"
  local enabled_path="$STREAMS_ENABLED_DIR/npmgr-$RULE_NAME.conf"
  local tmp_path="${available_path}.tmp"
  build_tcp_nginx_config >"$tmp_path"
  mv "$tmp_path" "$available_path"
  safe_symlink "$available_path" "$enabled_path"
}

remove_rendered_rule() {
  local rule_name="$1"
  rm -f "$SITES_AVAILABLE_DIR/npmgr-$rule_name.conf" \
        "$SITES_ENABLED_DIR/npmgr-$rule_name.conf" \
        "$STREAMS_AVAILABLE_DIR/npmgr-$rule_name.conf" \
        "$STREAMS_ENABLED_DIR/npmgr-$rule_name.conf"
}

ensure_layout() {
  ensure_directory "$RULES_DIR"
  ensure_directory "$CERTS_DIR"
  ensure_directory "$RUNTIME_DIR"
  ensure_directory "$SITES_AVAILABLE_DIR"
  ensure_directory "$SITES_ENABLED_DIR"
  ensure_directory "$STREAMS_AVAILABLE_DIR"
  ensure_directory "$STREAMS_ENABLED_DIR"
  ensure_directory "$NPMGR_NGINX_ETC/modules-enabled"
  ensure_directory "$NPMGR_NGINX_ETC/conf.d"
  cleanup_legacy_stream_config
}

cleanup_legacy_stream_config() {
  local module_file="$NPMGR_NGINX_ETC/modules-enabled/50-mod-stream.conf"
  local stream_conf="$NPMGR_NGINX_ETC/conf.d/npmgr-stream-includes.conf"
  rm -f "$stream_conf"
  if [[ -f "$module_file" ]] && grep -Fx 'load_module modules/ngx_stream_module.so;' "$module_file" >/dev/null 2>&1; then
    rm -f "$module_file"
  fi
}

install_include_snippets() {
  write_file "$NPMGR_NGINX_ETC/conf.d/npmgr-http-includes.conf" "include $SITES_ENABLED_DIR/*.conf;
"
  cleanup_legacy_stream_config
}

nginx_version_output() {
  nginx -V 2>&1 || true
}

nginx_has_builtin_stream() {
  nginx_version_output | grep -Eq '(^|[[:space:]])--with-stream([[:space:]]|$)'
}

nginx_modules_path() {
  local output modules_path
  output="$(nginx_version_output)"
  modules_path="$(printf '%s\n' "$output" | sed -n 's/.*--modules-path=\([^[:space:]]*\).*/\1/p' | head -n 1)"
  if [[ -n "$modules_path" ]]; then
    printf '%s' "$modules_path"
  elif [[ -d /usr/lib/nginx/modules ]]; then
    printf '/usr/lib/nginx/modules'
  elif [[ -d /usr/share/nginx/modules ]]; then
    printf '/usr/share/nginx/modules'
  else
    printf '%s' "$NPMGR_NGINX_ETC/modules"
  fi
}

find_stream_module_file() {
  local modules_path
  modules_path="$(nginx_modules_path)"
  local candidates=(
    "$modules_path/ngx_stream_module.so"
    "$NPMGR_NGINX_ETC/modules/ngx_stream_module.so"
    "/usr/lib/nginx/modules/ngx_stream_module.so"
    "/usr/share/nginx/modules/ngx_stream_module.so"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

install_stream_module_loader() {
  local module_file="$NPMGR_NGINX_ETC/modules-enabled/50-mod-stream.conf"
  cleanup_legacy_stream_config
  if nginx_has_builtin_stream; then
    rm -f "$module_file"
    return 0
  fi
  local stream_module
  if ! stream_module="$(find_stream_module_file)"; then
    return 1
  fi
  write_file "$module_file" "load_module ${stream_module};
"
}

install_stream_include_block() {
  local nginx_conf="$NPMGR_NGINX_ETC/nginx.conf"
  [[ -f "$nginx_conf" ]] || die "找不到 Nginx 主配置文件: $nginx_conf"
  if grep -F 'BEGIN nginx-proxy-manager stream include' "$nginx_conf" >/dev/null 2>&1; then
    return
  fi
  local tmp_path="${nginx_conf}.npmgr.tmp"
  cat "$nginx_conf" >"$tmp_path"
  cat >>"$tmp_path" <<EOF

# BEGIN nginx-proxy-manager stream include
stream {
    include $STREAMS_ENABLED_DIR/*.conf;
}
# END nginx-proxy-manager stream include
EOF
  mv "$tmp_path" "$nginx_conf"
}

ensure_stream_support() {
  require_command nginx
  if ! install_stream_module_loader; then
    die "Nginx stream 模块不可用，TCP 转发功能需要先安装 stream 模块。Debian 通常可执行：apt-get install -y libnginx-mod-stream"
  fi
  install_stream_include_block
}

check_debian_13() {
  if [[ "$NPMGR_TEST_MODE" == "1" ]]; then
    return
  fi
  [[ -f /etc/os-release ]] || die "无法识别系统版本。"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "debian" ]] || die "当前仅支持 Debian。"
  [[ "${VERSION_ID:-}" == "13" ]] || die "当前仅针对 Debian 13 做兼容保证。"
}

install_dependencies() {
  "$NPMGR_APT_GET_BIN" update
  "$NPMGR_APT_GET_BIN" install -y nginx curl jq cron
}

install_acme_sh() {
  if command_exists acme.sh; then
    return
  fi
  if [[ "$NPMGR_TEST_MODE" == "1" ]]; then
    :
  fi
  local install_script
  install_script="$(curl -fsSL https://get.acme.sh)"
  if ! printf '%s\n' "$install_script" | sh; then
    warn "acme.sh 默认安装失败，尝试使用 --force 跳过 crontab 检查。"
    printf '%s\n' "$install_script" | sh -s -- --force
  fi
}

assert_runtime_dependencies() {
  require_command nginx
  require_command curl
  require_command jq
  if command_exists acme.sh; then
    return
  fi
  [[ -x "$NPMGR_ACME_HOME/acme.sh" ]] || require_command acme.sh
}

get_acme_cmd() {
  if command_exists acme.sh; then
    printf 'acme.sh'
  elif [[ -x "$NPMGR_ACME_HOME/acme.sh" ]]; then
    printf '%s' "$NPMGR_ACME_HOME/acme.sh"
  else
    die "找不到 acme.sh"
  fi
}

reload_nginx() {
  require_command nginx
  nginx -t >/dev/null
  "$NPMGR_SYSTEMCTL_BIN" reload nginx
}

cf_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"
  load_cloudflare_credentials
  [[ -n "${CF_Token:-}" ]] || die "缺少 Cloudflare Token，请设置 CF_Token。"
  local url="https://api.cloudflare.com/client/v4${endpoint}"
  if [[ -n "$data" ]]; then
    curl -sS -X "$method" "$url" \
      -H "Authorization: Bearer $CF_Token" \
      -H "Content-Type: application/json" \
      --data "$data"
  else
    curl -sS -X "$method" "$url" \
      -H "Authorization: Bearer $CF_Token" \
      -H "Content-Type: application/json"
  fi
}

cf_dns_check() {
  local output
  output="$(cf_api GET "/user/tokens/verify")"
  if [[ "$(printf '%s' "$output" | jq -r '.success')" != "true" ]]; then
    warn "Cloudflare Token 校验失败。"
    return 1
  fi
  log "Cloudflare Token 校验通过。"
}

ensure_cf_success() {
  local response="$1"
  local action="$2"
  local message
  if [[ "$(printf '%s' "$response" | jq -r '.success')" != "true" ]]; then
    message="$(printf '%s' "$response" | jq -r '.errors[0].message // empty')"
    [[ -n "$message" ]] || message="Cloudflare 未返回具体错误"
    warn "${action}失败：${message}"
    return 1
  fi
}

ensure_cf_zone() {
  if [[ -z "${CF_ZONE:-}" ]]; then
    warn "启用自动 DNS 时必须提供 CF_ZONE。"
    return 1
  fi
  [[ -n "${CF_RECORD_NAME:-}" ]] || CF_RECORD_NAME="$SERVER_NAME"
}

normalize_cf_record_name() {
  local record_name="$1"
  local zone_name="$2"
  if [[ "$record_name" == "$zone_name" ]]; then
    printf '%s' "$record_name"
  elif [[ "$record_name" == *".${zone_name}" ]]; then
    printf '%s' "$record_name"
  else
    printf '%s.%s' "$record_name" "$zone_name"
  fi
}

sync_dns_record() {
  ensure_cf_zone || return 1
  cf_dns_check >/dev/null || return 1
  local zone_response zone_id dns_name ip_address lookup_response record_id payload
  zone_response="$(cf_api GET "/zones?name=${CF_ZONE}")"
  ensure_cf_success "$zone_response" "查询 Cloudflare 域名区域" || return 1
  zone_id="$(printf '%s' "$zone_response" | jq -r '.result[0].id // empty')"
  if [[ -z "$zone_id" ]]; then
    warn "找不到 Cloudflare 域名区域：$CF_ZONE"
    return 1
  fi
  dns_name="$(normalize_cf_record_name "$CF_RECORD_NAME" "$CF_ZONE")"
  ip_address="${PUBLIC_IP_OVERRIDE:-$(curl -sS https://api.ipify.org)}"
  lookup_response="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&name=${dns_name}")"
  ensure_cf_success "$lookup_response" "查询 Cloudflare DNS 记录" || return 1
  record_id="$(printf '%s' "$lookup_response" | jq -r '.result[0].id // empty')"
  payload=$(cat <<EOF
{"type":"A","name":"${dns_name}","content":"${ip_address}","ttl":1,"proxied":false}
EOF
)
  local write_response
  if [[ -n "$record_id" ]]; then
    write_response="$(cf_api PUT "/zones/${zone_id}/dns_records/${record_id}" "$payload")"
    ensure_cf_success "$write_response" "更新 Cloudflare DNS 记录" || return 1
    log "DNS 记录已更新：${dns_name} -> ${ip_address}"
  else
    write_response="$(cf_api POST "/zones/${zone_id}/dns_records" "$payload")"
    ensure_cf_success "$write_response" "创建 Cloudflare DNS 记录" || return 1
    log "DNS 记录已创建：${dns_name} -> ${ip_address}"
  fi
}

issue_certificate() {
  local domain="$1"
  local acme_cmd
  acme_cmd="$(get_acme_cmd)"
  load_cloudflare_credentials
  [[ -n "${CF_Token:-}" ]] || die "申请证书前请设置 CF_Token。"
  ensure_directory "$CERTS_DIR/$domain"
  ensure_directory "$RUNTIME_DIR"
  if ! CF_Token="$CF_Token" "$acme_cmd" --home "$NPMGR_ACME_HOME" --server "$NPMGR_ACME_SERVER" --issue --dns dns_cf -d "$domain" \
    --debug 2 --log "$ACME_LOG_FILE" >/dev/null 2>&1; then
    if grep -Eq 'Domains not changed|Skipping\. Next renewal time|Add .--force. to force renewal|not due for renewal' "$ACME_LOG_FILE" 2>/dev/null; then
      log "检测到 ${domain} 已有证书且未到续期时间，继续安装已有证书。"
    else
      return 1
    fi
  fi
  CF_Token="$CF_Token" "$acme_cmd" --home "$NPMGR_ACME_HOME" --server "$NPMGR_ACME_SERVER" --install-cert -d "$domain" \
    --fullchain-file "$CERTS_DIR/$domain/fullchain.pem" \
    --key-file "$CERTS_DIR/$domain/privkey.pem" \
    --debug 2 --log "$ACME_LOG_FILE" >/dev/null 2>&1 || return 1
}

render_rule_from_file() {
  local rule_name="$1"
  unset RULE_NAME RULE_TYPE SERVER_NAME LISTEN_PORT UPSTREAM_HOST UPSTREAM_PORT UPSTREAM_PROTO ENABLE_HTTPS AUTO_DNS CF_ZONE CF_RECORD_NAME CERT_MODE ENABLED TLS_MODE
  load_rule "$rule_name"
  if [[ "${ENABLED:-on}" != "on" ]]; then
    remove_rendered_rule "$RULE_NAME"
    return
  fi
  if [[ "$RULE_TYPE" == "http" ]]; then
    render_http_rule
  elif [[ "$RULE_TYPE" == "tcp" ]]; then
    render_tcp_rule
  else
    die "未知规则类型: $RULE_TYPE"
  fi
}

save_http_rule() {
  local path="$RULES_DIR/$RULE_NAME.conf"
  save_rule_file "$path" "$(build_http_rule_content)"
}

save_tcp_rule() {
  local path="$RULES_DIR/$RULE_NAME.conf"
  save_rule_file "$path" "$(build_tcp_rule_content)"
}

run_and_capture_failure() {
  set +e
  "$@"
  local status=$?
  set -e
  return "$status"
}

port_conflict_check() {
  local requested_port="$1"
  local ignored_rule="${2:-}"
  local path existing_port existing_rule
  local saved_rule_name="${RULE_NAME-}"
  local saved_rule_type="${RULE_TYPE-}"
  local saved_server_name="${SERVER_NAME-}"
  local saved_listen_port="${LISTEN_PORT-}"
  local saved_upstream_host="${UPSTREAM_HOST-}"
  local saved_upstream_port="${UPSTREAM_PORT-}"
  local saved_upstream_proto="${UPSTREAM_PROTO-}"
  local saved_enable_https="${ENABLE_HTTPS-}"
  local saved_auto_dns="${AUTO_DNS-}"
  local saved_cf_zone="${CF_ZONE-}"
  local saved_cf_record_name="${CF_RECORD_NAME-}"
  local saved_cert_mode="${CERT_MODE-}"
  local saved_enabled="${ENABLED-}"
  local saved_tls_mode="${TLS_MODE-}"
  shopt -s nullglob
  for path in "$RULES_DIR"/*.conf; do
    unset RULE_NAME RULE_TYPE SERVER_NAME LISTEN_PORT UPSTREAM_HOST UPSTREAM_PORT UPSTREAM_PROTO ENABLE_HTTPS AUTO_DNS CF_ZONE CF_RECORD_NAME CERT_MODE ENABLED TLS_MODE
    # shellcheck disable=SC1090
    source "$path"
    existing_rule="${RULE_NAME:-}"
    existing_port="${LISTEN_PORT:-}"
    if [[ "$existing_rule" != "$ignored_rule" && "${ENABLED:-on}" == "on" && "$existing_port" == "$requested_port" ]]; then
      die "监听端口冲突: $requested_port 已被规则 $existing_rule 使用。"
    fi
  done
  shopt -u nullglob
  RULE_NAME="$saved_rule_name"
  RULE_TYPE="$saved_rule_type"
  SERVER_NAME="$saved_server_name"
  LISTEN_PORT="$saved_listen_port"
  UPSTREAM_HOST="$saved_upstream_host"
  UPSTREAM_PORT="$saved_upstream_port"
  UPSTREAM_PROTO="$saved_upstream_proto"
  ENABLE_HTTPS="$saved_enable_https"
  AUTO_DNS="$saved_auto_dns"
  CF_ZONE="$saved_cf_zone"
  CF_RECORD_NAME="$saved_cf_record_name"
  CERT_MODE="$saved_cert_mode"
  ENABLED="$saved_enabled"
  TLS_MODE="$saved_tls_mode"
}

apply_http_side_effects() {
  if [[ "$AUTO_DNS" == "on" ]]; then
    sync_dns_record || return 1
  fi
  if [[ "$ENABLE_HTTPS" == "on" ]]; then
    issue_certificate "$SERVER_NAME" || return 1
  fi
}

disable_rule_file() {
  local rule_name="$1"
  local path="$RULES_DIR/$rule_name.conf"
  [[ -f "$path" ]] || return 0
  sed "s/^ENABLED=.*/ENABLED=off/" "$path" >"${path}.tmp"
  mv "${path}.tmp" "$path"
}

handle_rule_apply_failure() {
  local rule_name="$1"
  local reason="$2"
  disable_rule_file "$rule_name"
  remove_rendered_rule "$rule_name"
  local message="规则已保存，但后续应用失败：${reason}。该规则已被自动禁用，请修正后用 edit 或 enable 重试。"
  if [[ "$reason" == *"证书"* ]]; then
    message="${message}acme 调试日志：${ACME_LOG_FILE}"
  fi
  die "$message"
}

apply_tcp_side_effects() {
  if [[ "$TLS_MODE" == "terminate" ]]; then
    issue_certificate "$SERVER_NAME" || return 1
  fi
}

add_http_rule() {
  RULE_NAME=''
  SERVER_NAME=''
  LISTEN_PORT='443'
  UPSTREAM_HOST='127.0.0.1'
  UPSTREAM_PORT=''
  UPSTREAM_PROTO='http'
  ENABLE_HTTPS='on'
  AUTO_DNS='off'
  CF_ZONE=''
  CF_RECORD_NAME=''
  CERT_MODE='dns_cf'
  ENABLED='on'

  parse_http_args "$@"
  validate_http_rule
  port_conflict_check "$LISTEN_PORT"
  save_http_rule
  local current_rule_name="$RULE_NAME"
  if [[ "$AUTO_DNS" == "on" ]]; then
    if ! run_and_capture_failure sync_dns_record; then
      handle_rule_apply_failure "$current_rule_name" "DNS 记录创建或更新失败"
    fi
  fi
  if [[ "$ENABLE_HTTPS" == "on" ]]; then
    if ! run_and_capture_failure issue_certificate "$SERVER_NAME"; then
      handle_rule_apply_failure "$current_rule_name" "证书申请失败"
    fi
  fi
  if ! run_and_capture_failure render_http_rule; then
    handle_rule_apply_failure "$current_rule_name" "Nginx 配置生成失败"
  fi
  reload_nginx
  log "HTTP 规则已创建: $current_rule_name"
}

add_tcp_rule() {
  RULE_NAME=''
  LISTEN_PORT=''
  UPSTREAM_HOST='127.0.0.1'
  UPSTREAM_PORT=''
  TLS_MODE='passthrough'
  SERVER_NAME=''
  CERT_MODE='dns_cf'
  ENABLED='on'

  parse_tcp_args "$@"
  validate_tcp_rule
  port_conflict_check "$LISTEN_PORT"
  ensure_stream_support
  save_tcp_rule
  local current_rule_name="$RULE_NAME"
  if ! run_and_capture_failure apply_tcp_side_effects; then
    handle_rule_apply_failure "$current_rule_name" "证书申请失败"
  fi
  if ! run_and_capture_failure render_tcp_rule; then
    handle_rule_apply_failure "$current_rule_name" "Nginx 配置生成失败"
  fi
  reload_nginx
  log "TCP 规则已创建: $current_rule_name"
}

list_rules() {
  local path count=0
  shopt -s nullglob
  for path in "$RULES_DIR"/*.conf; do
    count=$((count + 1))
    unset RULE_NAME RULE_TYPE LISTEN_PORT ENABLED SERVER_NAME
    # shellcheck disable=SC1090
    source "$path"
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "${RULE_NAME:-未知}" "${RULE_TYPE:-未知}" "${LISTEN_PORT:-0}" "${ENABLED:-on}" "${SERVER_NAME:-}"
  done
  shopt -u nullglob
  if [[ $count -eq 0 ]]; then
    log "当前没有规则。"
  fi
}

show_rule() {
  local rule_name="$1"
  local path="$RULES_DIR/$rule_name.conf"
  [[ -f "$path" ]] || die "规则不存在: $rule_name"
  cat "$path"
}

delete_rule() {
  local rule_name="$1"
  load_rule "$rule_name"
  rm -f "$RULES_DIR/$rule_name.conf"
  remove_rendered_rule "$rule_name"
  if [[ -n "${SERVER_NAME:-}" ]]; then
    rm -rf "$CERTS_DIR/$SERVER_NAME"
  fi
  reload_nginx
  log "规则已删除: $rule_name"
}

set_rule_enabled_state() {
  local rule_name="$1"
  local desired_state="$2"
  load_rule "$rule_name"
  local path="$RULES_DIR/$rule_name.conf"
  sed "s/^ENABLED=.*/ENABLED=${desired_state}/" "$path" >"${path}.tmp"
  mv "${path}.tmp" "$path"
  render_rule_from_file "$rule_name"
  reload_nginx
  if [[ "$desired_state" == "on" ]]; then
    log "规则 ${rule_name} 已启用。"
  else
    log "规则 ${rule_name} 已禁用。"
  fi
}

edit_rule() {
  local rule_name="$1"
  shift || true
  load_rule "$rule_name"
  if [[ "$RULE_TYPE" == "http" ]]; then
    load_existing_http_defaults
    RULE_NAME="$rule_name"
    parse_http_args "$@"
    validate_http_rule
    port_conflict_check "$LISTEN_PORT" "$rule_name"
    save_http_rule
    if [[ "$AUTO_DNS" == "on" ]]; then
      if ! run_and_capture_failure sync_dns_record; then
        handle_rule_apply_failure "$RULE_NAME" "DNS 记录创建或更新失败"
      fi
    fi
    if [[ "$ENABLE_HTTPS" == "on" ]]; then
      if ! run_and_capture_failure issue_certificate "$SERVER_NAME"; then
        handle_rule_apply_failure "$RULE_NAME" "证书申请失败"
      fi
    fi
  else
    load_existing_tcp_defaults
    RULE_NAME="$rule_name"
    parse_tcp_args "$@"
    validate_tcp_rule
    port_conflict_check "$LISTEN_PORT" "$rule_name"
    save_tcp_rule
    if ! run_and_capture_failure apply_tcp_side_effects; then
      handle_rule_apply_failure "$RULE_NAME" "证书申请失败"
    fi
  fi
  if ! run_and_capture_failure render_rule_from_file "$rule_name"; then
    handle_rule_apply_failure "$RULE_NAME" "Nginx 配置生成失败"
  fi
  reload_nginx
  log "规则已更新: $rule_name"
}

renew_certs() {
  local acme_cmd
  acme_cmd="$(get_acme_cmd)"
  "$acme_cmd" --home "$NPMGR_ACME_HOME" --cron >/dev/null
  reload_nginx
  log "证书续期任务已执行。"
}

save_cloudflare_credentials() {
  local token="${1:-}"
  [[ -n "$token" ]] || die "Cloudflare Token 不能为空。"
  local quoted_token
  printf -v quoted_token '%q' "$token"
  write_file "$NPMGR_CF_CONFIG" "CF_Token=${quoted_token}
"
  chmod 600 "$NPMGR_CF_CONFIG" 2>/dev/null || true
  log "Cloudflare 凭证已保存。"
}

parse_http_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) RULE_NAME="$2"; shift 2 ;;
      --domain) SERVER_NAME="$2"; shift 2 ;;
      --listen) LISTEN_PORT="$2"; shift 2 ;;
      --upstream-host) UPSTREAM_HOST="$2"; shift 2 ;;
      --upstream-port) UPSTREAM_PORT="$2"; shift 2 ;;
      --upstream-proto) UPSTREAM_PROTO="$2"; shift 2 ;;
      --https) ENABLE_HTTPS="$(bool_normalize "$2")"; shift 2 ;;
      --auto-dns) AUTO_DNS="$(bool_normalize "$2")"; shift 2 ;;
      --cf-zone) CF_ZONE="$2"; shift 2 ;;
      --cf-record-name) CF_RECORD_NAME="$2"; shift 2 ;;
      --cert-mode) CERT_MODE="$2"; shift 2 ;;
      --enabled) ENABLED="$(bool_normalize "$2")"; shift 2 ;;
      *) die "未知 HTTP 参数: $1" ;;
    esac
  done
}

parse_tcp_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) RULE_NAME="$2"; shift 2 ;;
      --listen) LISTEN_PORT="$2"; shift 2 ;;
      --upstream-host) UPSTREAM_HOST="$2"; shift 2 ;;
      --upstream-port) UPSTREAM_PORT="$2"; shift 2 ;;
      --tls-mode) TLS_MODE="$2"; shift 2 ;;
      --domain) SERVER_NAME="$2"; shift 2 ;;
      --cert-mode) CERT_MODE="$2"; shift 2 ;;
      --enabled) ENABLED="$(bool_normalize "$2")"; shift 2 ;;
      *) die "未知 TCP 参数: $1" ;;
    esac
  done
}

usage() {
  cat <<EOF
用法:
  $SCRIPT_NAME install
  $SCRIPT_NAME set-cf-credentials --token <token>
  $SCRIPT_NAME add-http [参数]
  $SCRIPT_NAME add-tcp [参数]
  $SCRIPT_NAME list
  $SCRIPT_NAME show <rule_name>
  $SCRIPT_NAME edit <rule_name> [参数]
  $SCRIPT_NAME delete <rule_name>
  $SCRIPT_NAME enable <rule_name>
  $SCRIPT_NAME disable <rule_name>
  $SCRIPT_NAME reload
  $SCRIPT_NAME renew-certs
  $SCRIPT_NAME cf-dns-check
  $SCRIPT_NAME version

示例:
  $SCRIPT_NAME set-cf-credentials --token xxxxxx
  $SCRIPT_NAME add-http --name blog --domain blog.example.com --listen 443 --upstream-host 127.0.0.1 --upstream-port 3000 --https on
  $SCRIPT_NAME add-tcp --name ssh-tls --listen 9443 --upstream-host 127.0.0.1 --upstream-port 22 --tls-mode terminate --domain ssh.example.com
EOF
}

prompt() {
  local label="$1"
  local default_value="${2:-}"
  local reply=''
  if [[ -n "$default_value" ]]; then
    read -r -p "$label [$default_value]: " reply
    printf '%s' "${reply:-$default_value}"
  else
    read -r -p "$label: " reply
    printf '%s' "$reply"
  fi
}

command_label() {
  case "$1" in
    install) printf '安装依赖并初始化环境' ;;
    set-cf-credentials) printf '设置 Cloudflare 凭证' ;;
    add-http) printf '添加 HTTP/HTTPS 反向代理' ;;
    add-tcp) printf '添加 TCP 转发规则' ;;
    list) printf '查看规则列表' ;;
    show) printf '查看单条规则详情' ;;
    edit) printf '修改已有规则' ;;
    delete) printf '删除规则' ;;
    enable) printf '启用规则' ;;
    disable) printf '禁用规则' ;;
    reload) printf '重新加载 Nginx' ;;
    renew-certs) printf '执行证书续期' ;;
    cf-dns-check) printf '检查 Cloudflare 凭据' ;;
    version) printf '查看脚本版本' ;;
    help) printf '查看帮助' ;;
    *) printf '%s' "$1" ;;
  esac
}

load_existing_http_defaults() {
  RULE_NAME="${RULE_NAME:-}"
  SERVER_NAME="${SERVER_NAME:-}"
  LISTEN_PORT="${LISTEN_PORT:-443}"
  UPSTREAM_HOST="${UPSTREAM_HOST:-127.0.0.1}"
  UPSTREAM_PORT="${UPSTREAM_PORT:-}"
  UPSTREAM_PROTO="${UPSTREAM_PROTO:-http}"
  ENABLE_HTTPS="${ENABLE_HTTPS:-on}"
  AUTO_DNS="${AUTO_DNS:-off}"
  CF_ZONE="${CF_ZONE:-}"
  CF_RECORD_NAME="${CF_RECORD_NAME:-}"
  CERT_MODE="${CERT_MODE:-dns_cf}"
  ENABLED="${ENABLED:-on}"
}

load_existing_tcp_defaults() {
  RULE_NAME="${RULE_NAME:-}"
  LISTEN_PORT="${LISTEN_PORT:-}"
  UPSTREAM_HOST="${UPSTREAM_HOST:-127.0.0.1}"
  UPSTREAM_PORT="${UPSTREAM_PORT:-}"
  TLS_MODE="${TLS_MODE:-passthrough}"
  SERVER_NAME="${SERVER_NAME:-}"
  CERT_MODE="${CERT_MODE:-dns_cf}"
  ENABLED="${ENABLED:-on}"
}

interactive_add_http() {
  local name domain listen upstream_host upstream_port https auto_dns cf_zone cf_record upstream_proto
  name="$(prompt '规则名')"
  domain="$(prompt '域名（可留空）' '')"
  listen="$(prompt '监听端口' '443')"
  upstream_host="$(prompt '上游地址' '127.0.0.1')"
  upstream_port="$(prompt '上游端口')"
  upstream_proto="$(prompt '上游协议（http/https）' 'http')"
  https="$(prompt '启用 HTTPS（on/off）' 'on')"
  auto_dns="$(prompt '自动管理 DNS（on/off）' 'off')"
  cf_zone=''
  cf_record=''
  if [[ "$auto_dns" == "on" ]]; then
    cf_zone="$(prompt 'Cloudflare 域名区域（Zone）')"
    cf_record="$(prompt 'DNS 记录名' "$domain")"
  fi
  add_http_rule --name "$name" --domain "$domain" --listen "$listen" --upstream-host "$upstream_host" --upstream-port "$upstream_port" --upstream-proto "$upstream_proto" --https "$https" --auto-dns "$auto_dns" --cf-zone "$cf_zone" --cf-record-name "$cf_record"
}

interactive_add_tcp() {
  local name listen upstream_host upstream_port tls_mode domain
  name="$(prompt '规则名')"
  listen="$(prompt '监听端口')"
  upstream_host="$(prompt '上游地址' '127.0.0.1')"
  upstream_port="$(prompt '上游端口')"
  tls_mode="$(prompt 'TLS 模式（passthrough/terminate）' 'passthrough')"
  domain=''
  if [[ "$tls_mode" == "terminate" ]]; then
    domain="$(prompt '证书域名')"
  fi
  add_tcp_rule --name "$name" --listen "$listen" --upstream-host "$upstream_host" --upstream-port "$upstream_port" --tls-mode "$tls_mode" --domain "$domain"
}

interactive_set_cloudflare_credentials() {
  local token
  token="$(prompt '请输入 Cloudflare API Token')"
  save_cloudflare_credentials "$token"
}

interactive_menu() {
  while true; do
    cat <<'EOF'
======== Nginx 代理管理 ========
1) 安装依赖并初始化环境
2) 设置 Cloudflare 凭证
3) 添加 HTTP/HTTPS 反向代理
4) 添加 TCP 转发规则
5) 查看规则列表
6) 查看单条规则详情
7) 修改已有规则
8) 删除规则
9) 启用规则
10) 禁用规则
11) 重新加载 Nginx
12) 执行证书续期
13) 检查 Cloudflare 凭据
0) 退出
EOF
    local choice
    choice="$(prompt '请选择操作' '0')"
    case "$choice" in
      1) run_install ;;
      2) interactive_set_cloudflare_credentials ;;
      3) interactive_add_http ;;
      4) interactive_add_tcp ;;
      5) list_rules ;;
      6) show_rule "$(prompt '规则名')" ;;
      7)
        local rule_name
        rule_name="$(prompt '规则名')"
        warn "修改规则的交互式逐字段向导暂未完成，请先使用命令行方式。"
        show_rule "$rule_name"
        ;;
      8) delete_rule "$(prompt '规则名')" ;;
      9) set_rule_enabled_state "$(prompt '规则名')" "on" ;;
      10) set_rule_enabled_state "$(prompt '规则名')" "off" ;;
      11) reload_nginx ;;
      12) renew_certs ;;
      13) cf_dns_check ;;
      0) break ;;
      *) warn "无效选择。" ;;
    esac
  done
}

parse_cf_credentials_args() {
  local token=''
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --token) token="$2"; shift 2 ;;
      *) die "未知 Cloudflare 凭证参数: $1" ;;
    esac
  done
  save_cloudflare_credentials "$token"
}

run_install() {
  require_root
  check_debian_13
  install_dependencies
  install_acme_sh
  ensure_layout
  install_include_snippets
  assert_runtime_dependencies
  log "安装/初始化完成。"
}

run_reload() {
  reload_nginx
  log "Nginx 已重载。"
}

main() {
  local command="${1:-}"
  if [[ -z "$command" ]]; then
    interactive_menu
    return
  fi

  shift || true

  case "$command" in
    install) run_install "$@" ;;
    set-cf-credentials)
      require_root
      ensure_layout
      parse_cf_credentials_args "$@"
      ;;
    add-http)
      require_root
      assert_runtime_dependencies
      ensure_layout
      add_http_rule "$@"
      ;;
    add-tcp)
      require_root
      assert_runtime_dependencies
      ensure_layout
      add_tcp_rule "$@"
      ;;
    list)
      ensure_layout
      list_rules
      ;;
    show)
      [[ $# -ge 1 ]] || die "$(command_label show) 需要规则名。"
      ensure_layout
      show_rule "$1"
      ;;
    edit)
      [[ $# -ge 1 ]] || die "$(command_label edit) 需要规则名。"
      require_root
      assert_runtime_dependencies
      ensure_layout
      local rule_name="$1"
      shift
      edit_rule "$rule_name" "$@"
      ;;
    delete)
      [[ $# -ge 1 ]] || die "$(command_label delete) 需要规则名。"
      require_root
      assert_runtime_dependencies
      ensure_layout
      delete_rule "$1"
      ;;
    enable)
      [[ $# -ge 1 ]] || die "$(command_label enable) 需要规则名。"
      require_root
      assert_runtime_dependencies
      ensure_layout
      set_rule_enabled_state "$1" "on"
      ;;
    disable)
      [[ $# -ge 1 ]] || die "$(command_label disable) 需要规则名。"
      require_root
      assert_runtime_dependencies
      ensure_layout
      set_rule_enabled_state "$1" "off"
      ;;
    reload)
      require_root
      run_reload
      ;;
    renew-certs)
      require_root
      assert_runtime_dependencies
      renew_certs
      ;;
    cf-dns-check)
      cf_dns_check
      ;;
    version|--version|-v)
      printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
      ;;
    help|--help|-h)
      usage
      ;;
    *)
      usage
      die "未知命令: $command"
      ;;
  esac
}

main "$@"
