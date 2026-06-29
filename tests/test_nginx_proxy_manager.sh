#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="$PROJECT_DIR/nginx-proxy-manager.sh"
TMP_ROOT=""

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" != *"$needle"* ]] || fail "expected output to not contain: $needle"
}

assert_file_contains() {
  local path="$1"
  local needle="$2"
  [[ -f "$path" ]] || fail "expected file to exist: $path"
  grep -F -- "$needle" "$path" >/dev/null || fail "expected $path to contain: $needle"
}

assert_not_exists() {
  local path="$1"
  [[ ! -e "$path" ]] || fail "expected path to not exist: $path"
}

assert_exists() {
  local path="$1"
  [[ -e "$path" ]] || fail "expected path to exist: $path"
}

assert_symlink_target() {
  local path="$1"
  local expected_target="$2"
  [[ -L "$path" ]] || fail "expected symlink to exist: $path"
  local actual_target
  actual_target="$(readlink "$path")"
  [[ "$actual_target" == "$expected_target" ]] || fail "expected symlink $path -> $expected_target, got $actual_target"
}

setup_env() {
  local with_acme="${1:-1}"
  local acme_issue_fail="${2:-0}"
  local with_stream="${3:-0}"
  TMP_ROOT="$(mktemp -d)"
  export NPMGR_TEST_MODE=1
  export NPMGR_BASE_DIR="$TMP_ROOT/etc/nginx-proxy-manager"
  export NPMGR_NGINX_ETC="$TMP_ROOT/etc/nginx"
  export NPMGR_ACME_HOME="$TMP_ROOT/acme"
  export NPMGR_CF_CONFIG="$TMP_ROOT/etc/nginx-proxy-manager/cloudflare.conf"
  export NPMGR_SYSTEMCTL_BIN="$TMP_ROOT/bin/systemctl"
  export NPMGR_APT_GET_BIN="$TMP_ROOT/bin/apt-get"
  export CF_Token="test-token"
  mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/etc/nginx/modules-enabled" "$TMP_ROOT/etc/nginx/conf.d"
  cat >"$TMP_ROOT/etc/nginx/nginx.conf" <<'EOF'
include modules-enabled/*.conf;
events {}
http {
  include conf.d/*.conf;
}
EOF
  if [[ "$with_stream" == "1" ]]; then
    mkdir -p "$TMP_ROOT/etc/nginx/modules"
    printf 'mock stream module' >"$TMP_ROOT/etc/nginx/modules/ngx_stream_module.so"
  fi
  cat >"$TMP_ROOT/bin/nginx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-t" ]]; then
  if [[ -f "${NPMGR_NGINX_ETC}/modules-enabled/50-mod-stream.conf" ]]; then
    module_path="$(sed -n 's/^[[:space:]]*load_module[[:space:]]\+\([^;]*\);.*/\1/p' "${NPMGR_NGINX_ETC}/modules-enabled/50-mod-stream.conf" | head -n 1)"
    if [[ "$module_path" == modules/* ]]; then
      module_path="${NPMGR_NGINX_ETC}/${module_path}"
    fi
    if [[ -n "$module_path" && ! -f "$module_path" ]]; then
      echo "nginx: dlopen() \"$module_path\" failed" >&2
      exit 1
    fi
  fi
  if [[ -f "${NPMGR_NGINX_ETC}/conf.d/npmgr-stream-includes.conf" ]]; then
    echo "nginx: \"stream\" directive is not allowed here" >&2
    exit 1
  fi
  if compgen -G "${NPMGR_NGINX_ETC}/streams-enabled/*.conf" >/dev/null; then
    if ! grep -F "BEGIN nginx-proxy-manager stream include" "${NPMGR_NGINX_ETC}/nginx.conf" >/dev/null 2>&1; then
      echo "nginx: no stream include configured" >&2
      exit 1
    fi
  fi
  if grep -R "INVALID_DIRECTIVE" "${NPMGR_NGINX_ETC}" >/dev/null 2>&1; then
    echo "nginx: configuration test failed" >&2
    exit 1
  fi
  echo "nginx: configuration file ${NPMGR_NGINX_ETC}/nginx.conf test is successful"
  exit 0
fi
if [[ "${1:-}" == "-V" ]]; then
  if [[ -f "${NPMGR_NGINX_ETC}/modules/ngx_stream_module.so" ]]; then
    echo "nginx version: nginx/1.26.3" >&2
    echo "configure arguments: --with-compat --with-stream=dynamic" >&2
  else
    echo "nginx version: nginx/1.26.3" >&2
    echo "configure arguments: --with-compat" >&2
  fi
  exit 0
fi
echo "fake nginx $*"
EOF
  cat >"$TMP_ROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"${NPMGR_BASE_DIR}/runtime/systemctl.log"
EOF
  cat >"$TMP_ROOT/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "${NPMGR_BASE_DIR}/runtime"
echo "$*" >>"${NPMGR_BASE_DIR}/runtime/apt-get.log"
EOF
  cat >"$TMP_ROOT/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"https://get.acme.sh"* ]]; then
  cat <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
if command -v crontab >/dev/null 2>&1 || [[ " $* " == *" --force "* ]]; then
  mkdir -p "$NPMGR_ACME_HOME"
  cat >"$NPMGR_ACME_HOME/acme.sh" <<'EOA'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"${NPMGR_BASE_DIR}/runtime/acme.log"
if [[ "$*" == *"--install-cert"* ]]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fullchain-file)
        shift
        mkdir -p "$(dirname "$1")"
        printf 'fullchain' >"$1"
        ;;
      --key-file)
        shift
        mkdir -p "$(dirname "$1")"
        printf 'privkey' >"$1"
        ;;
    esac
    shift || true
  done
fi
EOA
  chmod +x "$NPMGR_ACME_HOME/acme.sh"
  exit 0
fi
echo "Pre-check failed, cannot install." >&2
exit 1
EOS
else
  mkdir -p "${NPMGR_BASE_DIR}/runtime"
  echo "$*" >>"${NPMGR_BASE_DIR}/runtime/curl.log"
  if [[ "$*" == *"api.ipify.org"* ]]; then
    echo "${MOCK_PUBLIC_IP:-203.0.113.10}"
    exit 0
  fi
  if [[ "$*" == *"/user/tokens/verify"* ]]; then
    echo '{"success":true,"result":{"status":"active"}}'
    exit 0
  fi
  if [[ "$*" == *"/zones?name=example.com"* ]]; then
    echo '{"success":true,"result":[{"id":"zone123","name":"example.com"}]}'
    exit 0
  fi
  if [[ "$*" == *"/dns_records?type=A&name=dns.example.com"* ]]; then
    echo '{"success":true,"result":[]}'
    exit 0
  fi
  if [[ "$*" == *"/zones/zone123/dns_records"* ]]; then
    if [[ "${MOCK_CF_DNS_WRITE_FAIL:-0}" == "1" ]]; then
      echo '{"success":false,"errors":[{"message":"missing permission"}]}'
    else
      echo '{"success":true,"result":{"id":"record123"}}'
    fi
    exit 0
  fi
  echo "${MOCK_CURL_RESPONSE:-{\"success\":true,\"result\":[]}}"
fi
EOF
  cat >"$TMP_ROOT/bin/jq" <<'EOF'
#!/usr/bin/env python3
import json, sys
data = json.load(sys.stdin)
args = [arg for arg in sys.argv[1:] if arg != '-r']
expr = args[0]
if expr == '.success':
    print('true' if data.get('success') else 'false')
elif expr == '.result[0].id // empty':
    result = data.get('result') or []
    print(result[0].get('id', '') if result else '')
elif expr == '.result[0].content // empty':
    result = data.get('result') or []
    print(result[0].get('content', '') if result else '')
elif expr == '.errors[0].message // empty':
    errors = data.get('errors') or []
    print(errors[0].get('message', '') if errors else '')
else:
    raise SystemExit(1)
EOF
  if [[ "$with_acme" == "1" ]]; then
    cat >"$TMP_ROOT/bin/acme.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
original_args="$*"
echo "$original_args" >>"${NPMGR_BASE_DIR}/runtime/acme.log"
log_file=''
args=("$@")
index=0
while [[ $index -lt ${#args[@]} ]]; do
  case "${args[$index]}" in
    --log)
      index=$((index + 1))
      log_file="${args[$index]:-}"
      ;;
  esac
  index=$((index + 1))
done
if [[ "${NPMGR_ACME_ISSUE_SKIP:-0}" == "1" && "$original_args" == *"--issue"* ]]; then
  if [[ -n "$log_file" ]]; then
    mkdir -p "$(dirname "$log_file")"
    printf 'Domains not changed.\nSkipping. Next renewal time is: 2026-08-28T02:52:58Z\nAdd --force to force renewal.\n' >>"$log_file"
  fi
  echo "[mock acme] skipping because cert is not due for renewal" >&2
  exit 2
fi
if [[ "${NPMGR_ACME_ISSUE_FAIL:-0}" == "1" && "$original_args" == *"--issue"* ]]; then
  if [[ -n "$log_file" ]]; then
    mkdir -p "$(dirname "$log_file")"
    printf 'mock acme issue failed\n' >>"$log_file"
  fi
  echo "[mock acme] issue failed" >&2
  exit 1
fi
if [[ "$original_args" == *"--install-cert"* ]]; then
  index=0
  while [[ $index -lt ${#args[@]} ]]; do
    case "${args[$index]}" in
      --fullchain-file)
        index=$((index + 1))
        mkdir -p "$(dirname "${args[$index]}")"
        printf 'fullchain' >"${args[$index]}"
        ;;
      --key-file)
        index=$((index + 1))
        mkdir -p "$(dirname "${args[$index]}")"
        printf 'privkey' >"${args[$index]}"
        ;;
    esac
    index=$((index + 1))
  done
fi
EOF
  fi
  chmod +x "$TMP_ROOT/bin/nginx" "$TMP_ROOT/bin/systemctl" "$TMP_ROOT/bin/apt-get" "$TMP_ROOT/bin/curl" "$TMP_ROOT/bin/jq"
  if [[ "$with_acme" == "1" ]]; then
    chmod +x "$TMP_ROOT/bin/acme.sh"
  fi
  export NPMGR_ACME_ISSUE_FAIL="$acme_issue_fail"
  export NPMGR_ACME_ISSUE_SKIP="${NPMGR_ACME_ISSUE_SKIP:-0}"
  export PATH="$TMP_ROOT/bin:$PATH"
}

teardown_env() {
  rm -rf "$TMP_ROOT"
}

run_cmd() {
  bash "$SCRIPT_PATH" "$@"
}

test_install_creates_layout() {
  setup_env
  run_cmd install >/tmp/npmgr-test.out
  assert_exists "$NPMGR_BASE_DIR/rules"
  assert_exists "$NPMGR_BASE_DIR/certs"
  assert_exists "$NPMGR_BASE_DIR/runtime"
  assert_exists "$NPMGR_NGINX_ETC/sites-available"
  assert_exists "$NPMGR_NGINX_ETC/streams-enabled"
  assert_file_contains "$NPMGR_NGINX_ETC/conf.d/npmgr-http-includes.conf" "sites-enabled/*.conf"
  assert_not_exists "$NPMGR_NGINX_ETC/modules-enabled/50-mod-stream.conf"
  assert_not_exists "$NPMGR_NGINX_ETC/conf.d/npmgr-stream-includes.conf"
  teardown_env
}

test_install_does_not_break_http_without_stream_module() {
  setup_env
  run_cmd install >/dev/null
  run_cmd add-http \
    --name nostream-http \
    --listen 8088 \
    --upstream-host 127.0.0.1 \
    --upstream-port 3000 \
    --https off >/tmp/npmgr-no-stream-http.out
  assert_file_contains "$NPMGR_BASE_DIR/rules/nostream-http.conf" "RULE_TYPE=http"
  assert_not_exists "$NPMGR_NGINX_ETC/modules-enabled/50-mod-stream.conf"
  assert_not_exists "$NPMGR_NGINX_ETC/conf.d/npmgr-stream-includes.conf"
  teardown_env
}

test_add_http_removes_legacy_broken_stream_loader() {
  setup_env 1 0 1
  mkdir -p "$NPMGR_NGINX_ETC/modules-enabled"
  printf 'load_module modules/ngx_stream_module.so;\n' >"$NPMGR_NGINX_ETC/modules-enabled/50-mod-stream.conf"
  run_cmd add-http \
    --name legacy-stream \
    --listen 8089 \
    --upstream-host 127.0.0.1 \
    --upstream-port 3000 \
    --https off >/tmp/npmgr-legacy-stream.out
  assert_file_contains "$NPMGR_BASE_DIR/rules/legacy-stream.conf" "RULE_TYPE=http"
  assert_not_exists "$NPMGR_NGINX_ETC/modules-enabled/50-mod-stream.conf"
  teardown_env
}

test_install_bootstraps_acme_without_crontab() {
  setup_env 0
  run_cmd install >/tmp/npmgr-install-acme.out
  assert_exists "$NPMGR_ACME_HOME/acme.sh"
  teardown_env
}

test_install_skips_unused_packages() {
  setup_env
  run_cmd install >/tmp/npmgr-install-deps.out
  local apt_log
  apt_log="$(cat "$NPMGR_BASE_DIR/runtime/apt-get.log")"
  assert_contains "$apt_log" "install -y nginx curl jq cron"
  assert_not_contains "$apt_log" "socat"
  teardown_env
}

test_add_http_generates_rule_and_nginx_config() {
  setup_env
  run_cmd install >/dev/null
  run_cmd add-http \
    --name blog \
    --domain blog.example.com \
    --listen 443 \
    --upstream-host 127.0.0.1 \
    --upstream-port 3000 \
    --https on \
    --auto-dns off >/tmp/npmgr-http.out
  assert_file_contains "$NPMGR_BASE_DIR/rules/blog.conf" "RULE_TYPE=http"
  assert_file_contains "$NPMGR_NGINX_ETC/sites-available/npmgr-blog.conf" "listen 443 ssl;"
  assert_file_contains "$NPMGR_NGINX_ETC/sites-available/npmgr-blog.conf" "server_name blog.example.com;"
  assert_file_contains "$NPMGR_NGINX_ETC/sites-available/npmgr-blog.conf" "proxy_pass http://127.0.0.1:3000;"
  assert_file_contains "$NPMGR_BASE_DIR/runtime/acme.log" "--server letsencrypt"
  assert_symlink_target "$NPMGR_NGINX_ETC/sites-enabled/npmgr-blog.conf" "$NPMGR_NGINX_ETC/sites-available/npmgr-blog.conf"
  assert_file_contains "$NPMGR_BASE_DIR/runtime/systemctl.log" "reload nginx"
  teardown_env
}

test_http_domain_rules_can_share_https_port() {
  setup_env
  run_cmd install >/dev/null
  export NPMGR_ACME_ISSUE_SKIP=1
  run_cmd add-http \
    --name lucky \
    --domain lucky.example.com \
    --listen 443 \
    --upstream-host 127.0.0.1 \
    --upstream-port 16601 \
    --https on \
    --auto-dns off >/tmp/npmgr-lucky.out
  run_cmd add-http \
    --name melonnet \
    --domain melonnet.example.com \
    --listen 443 \
    --upstream-host 127.0.0.1 \
    --upstream-port 80 \
    --https on \
    --auto-dns off >/tmp/npmgr-melonnet.out
  assert_file_contains "$NPMGR_NGINX_ETC/sites-available/npmgr-lucky.conf" "server_name lucky.example.com;"
  assert_file_contains "$NPMGR_NGINX_ETC/sites-available/npmgr-melonnet.conf" "server_name melonnet.example.com;"
  unset NPMGR_ACME_ISSUE_SKIP
  teardown_env
}

test_http_same_domain_same_port_is_rejected() {
  setup_env
  run_cmd install >/dev/null
  run_cmd add-http \
    --name app1 \
    --domain same.example.com \
    --listen 443 \
    --upstream-host 127.0.0.1 \
    --upstream-port 3000 \
    --https off >/dev/null
  if run_cmd add-http \
    --name app2 \
    --domain same.example.com \
    --listen 443 \
    --upstream-host 127.0.0.1 \
    --upstream-port 3001 \
    --https off >/tmp/npmgr-same-domain.out 2>&1; then
    fail "expected same HTTP domain and port to be rejected"
  fi
  assert_contains "$(cat /tmp/npmgr-same-domain.out)" "监听端口冲突"
  teardown_env
}

test_add_http_reports_cert_failure_and_keeps_rule() {
  setup_env 1 1
  run_cmd install >/dev/null
  if run_cmd add-http \
    --name broken-cert \
    --domain broken.example.com \
    --listen 443 \
    --upstream-host 127.0.0.1 \
    --upstream-port 3000 \
    --https on \
    --auto-dns off >/tmp/npmgr-cert-fail.out 2>&1; then
    fail "expected add-http to fail when certificate issuance fails"
  fi
  assert_file_contains "$NPMGR_BASE_DIR/rules/broken-cert.conf" "RULE_NAME=broken-cert"
  assert_file_contains "$NPMGR_BASE_DIR/rules/broken-cert.conf" "ENABLED=off"
  assert_contains "$(cat /tmp/npmgr-cert-fail.out)" "证书"
  assert_contains "$(cat /tmp/npmgr-cert-fail.out)" "acme.sh.log"
  assert_exists "$NPMGR_BASE_DIR/runtime/acme.sh.log"
  teardown_env
}

test_add_http_reuses_existing_certificate_when_acme_skips_issue() {
  export NPMGR_ACME_ISSUE_SKIP=1
  setup_env
  run_cmd install >/dev/null
  run_cmd add-http \
    --name existing-cert \
    --domain existing.example.com \
    --listen 443 \
    --upstream-host 127.0.0.1 \
    --upstream-port 3000 \
    --https on \
    --auto-dns off >/tmp/npmgr-existing-cert.out
  assert_file_contains "$NPMGR_BASE_DIR/rules/existing-cert.conf" "ENABLED=on"
  assert_file_contains "$NPMGR_NGINX_ETC/sites-available/npmgr-existing-cert.conf" "listen 443 ssl;"
  assert_exists "$NPMGR_BASE_DIR/certs/existing.example.com/fullchain.pem"
  assert_exists "$NPMGR_BASE_DIR/certs/existing.example.com/privkey.pem"
  assert_contains "$(cat /tmp/npmgr-existing-cert.out)" "已有证书"
  unset NPMGR_ACME_ISSUE_SKIP
  teardown_env
}

test_auto_dns_creates_cloudflare_record() {
  setup_env
  run_cmd install >/dev/null
  run_cmd add-http \
    --name dnsapp \
    --domain dns.example.com \
    --listen 444 \
    --upstream-host 127.0.0.1 \
    --upstream-port 3000 \
    --https off \
    --auto-dns on \
    --cf-zone example.com \
    --cf-record-name dns.example.com >/tmp/npmgr-dns-create.out
  assert_file_contains "$NPMGR_BASE_DIR/runtime/curl.log" "-X POST"
  assert_file_contains "$NPMGR_BASE_DIR/runtime/curl.log" "/zones/zone123/dns_records"
  assert_not_contains "$(cat "$NPMGR_BASE_DIR/runtime/curl.log")" '/zones/"zone123"/dns_records'
  teardown_env
}

test_auto_dns_accepts_short_record_name() {
  setup_env
  run_cmd install >/dev/null
  run_cmd add-http \
    --name dnsshort \
    --domain dns.example.com \
    --listen 446 \
    --upstream-host 127.0.0.1 \
    --upstream-port 3000 \
    --https off \
    --auto-dns on \
    --cf-zone example.com \
    --cf-record-name dns >/tmp/npmgr-dns-short.out
  assert_file_contains "$NPMGR_BASE_DIR/runtime/curl.log" "/dns_records?type=A&name=dns.example.com"
  assert_contains "$(cat /tmp/npmgr-dns-short.out)" "DNS 记录已创建"
  assert_contains "$(cat "$NPMGR_BASE_DIR/runtime/curl.log")" '"name":"dns.example.com"'
  teardown_env
}

test_auto_dns_failure_is_reported_and_rule_kept_disabled() {
  setup_env
  export MOCK_CF_DNS_WRITE_FAIL=1
  run_cmd install >/dev/null
  if run_cmd add-http \
    --name dnsfail \
    --domain dns.example.com \
    --listen 445 \
    --upstream-host 127.0.0.1 \
    --upstream-port 3000 \
    --https off \
    --auto-dns on \
    --cf-zone example.com \
    --cf-record-name dns.example.com >/tmp/npmgr-dns-fail.out 2>&1; then
    fail "expected add-http to fail when Cloudflare DNS write fails"
  fi
  assert_file_contains "$NPMGR_BASE_DIR/rules/dnsfail.conf" "ENABLED=off"
  assert_contains "$(cat /tmp/npmgr-dns-fail.out)" "DNS"
  teardown_env
}

test_add_tcp_tls_generates_stream_config_and_cert_files() {
  setup_env 1 0 1
  run_cmd install >/dev/null
  run_cmd add-tcp \
    --name ssh-tls \
    --listen 9443 \
    --upstream-host 127.0.0.1 \
    --upstream-port 22 \
    --tls-mode terminate \
    --domain ssh.example.com >/tmp/npmgr-tcp.out
  assert_file_contains "$NPMGR_BASE_DIR/rules/ssh-tls.conf" "TLS_MODE=terminate"
  assert_file_contains "$NPMGR_NGINX_ETC/streams-available/npmgr-ssh-tls.conf" "listen 9443 ssl;"
  assert_file_contains "$NPMGR_NGINX_ETC/streams-available/npmgr-ssh-tls.conf" "proxy_pass 127.0.0.1:22;"
  assert_exists "$NPMGR_BASE_DIR/certs/ssh.example.com/fullchain.pem"
  assert_exists "$NPMGR_BASE_DIR/certs/ssh.example.com/privkey.pem"
  teardown_env
}

test_add_tcp_requires_stream_module() {
  setup_env
  run_cmd install >/dev/null
  if run_cmd add-tcp \
    --name tcp-no-stream \
    --listen 9444 \
    --upstream-host 127.0.0.1 \
    --upstream-port 22 \
    --tls-mode passthrough >/tmp/npmgr-tcp-no-stream.out 2>&1; then
    fail "expected add-tcp to fail when stream module is unavailable"
  fi
  assert_contains "$(cat /tmp/npmgr-tcp-no-stream.out)" "stream 模块"
  assert_contains "$(cat /tmp/npmgr-tcp-no-stream.out)" "libnginx-mod-stream"
  assert_not_exists "$NPMGR_BASE_DIR/rules/tcp-no-stream.conf"
  teardown_env
}

test_invalid_port_is_rejected() {
  setup_env
  run_cmd install >/dev/null
  if run_cmd add-http \
    --name broken \
    --listen 99999 \
    --upstream-host 127.0.0.1 \
    --upstream-port 3000 \
    --https off >/tmp/npmgr-invalid.out 2>&1; then
    fail "expected invalid port command to fail"
  fi
  assert_not_exists "$NPMGR_BASE_DIR/rules/broken.conf"
  teardown_env
}

test_delete_removes_rule_and_configs() {
  setup_env
  run_cmd install >/dev/null
  run_cmd add-http \
    --name oldapp \
    --listen 8080 \
    --upstream-host 127.0.0.1 \
    --upstream-port 9000 \
    --https off >/dev/null
  run_cmd delete oldapp >/tmp/npmgr-delete.out
  assert_not_exists "$NPMGR_BASE_DIR/rules/oldapp.conf"
  assert_not_exists "$NPMGR_NGINX_ETC/sites-available/npmgr-oldapp.conf"
  assert_not_exists "$NPMGR_NGINX_ETC/sites-enabled/npmgr-oldapp.conf"
  teardown_env
}

test_list_and_show_display_rule_details() {
  setup_env
  run_cmd install >/dev/null
  run_cmd add-http \
    --name app1 \
    --listen 8081 \
    --upstream-host 192.168.1.10 \
    --upstream-port 8080 \
    --https off >/dev/null
  local list_output
  local show_output
  list_output="$(run_cmd list)"
  show_output="$(run_cmd show app1)"
  assert_contains "$list_output" "app1"
  assert_contains "$show_output" "UPSTREAM_HOST=192.168.1.10"
  teardown_env
}

test_edit_and_enable_disable_work() {
  setup_env
  run_cmd install >/dev/null
  run_cmd add-http \
    --name editme \
    --listen 8082 \
    --upstream-host 127.0.0.1 \
    --upstream-port 9000 \
    --https off >/dev/null
  run_cmd edit editme --upstream-port 9001 >/tmp/npmgr-edit.out
  assert_file_contains "$NPMGR_BASE_DIR/rules/editme.conf" "UPSTREAM_PORT=9001"
  run_cmd disable editme >/tmp/npmgr-disable.out
  assert_file_contains "$NPMGR_BASE_DIR/rules/editme.conf" "ENABLED=off"
  assert_not_exists "$NPMGR_NGINX_ETC/sites-available/npmgr-editme.conf"
  run_cmd enable editme >/tmp/npmgr-enable.out
  assert_file_contains "$NPMGR_BASE_DIR/rules/editme.conf" "ENABLED=on"
  assert_exists "$NPMGR_NGINX_ETC/sites-available/npmgr-editme.conf"
  teardown_env
}

test_reload_renew_and_cf_check_work() {
  setup_env
  run_cmd install >/dev/null
  run_cmd reload >/tmp/npmgr-reload.out
  run_cmd renew-certs >/tmp/npmgr-renew.out
  run_cmd cf-dns-check >/tmp/npmgr-cfcheck.out
  assert_file_contains "$NPMGR_BASE_DIR/runtime/systemctl.log" "reload nginx"
  assert_file_contains "$NPMGR_BASE_DIR/runtime/acme.log" "--cron"
  assert_contains "$(cat /tmp/npmgr-cfcheck.out)" "校验通过"
  teardown_env
}

test_reload_removes_legacy_stream_include() {
  setup_env
  run_cmd install >/dev/null
  printf 'stream { include %s/*.conf; }\n' "$NPMGR_NGINX_ETC/streams-enabled" >"$NPMGR_NGINX_ETC/conf.d/npmgr-stream-includes.conf"
  run_cmd reload >/tmp/npmgr-reload-legacy-stream.out
  assert_not_exists "$NPMGR_NGINX_ETC/conf.d/npmgr-stream-includes.conf"
  assert_file_contains "$NPMGR_BASE_DIR/runtime/systemctl.log" "reload nginx"
  teardown_env
}

test_save_cloudflare_credentials_and_auto_load() {
  setup_env
  unset CF_Token
  run_cmd install >/dev/null
  run_cmd set-cf-credentials --token saved-token >/tmp/npmgr-cf-save.out
  assert_file_contains "$NPMGR_CF_CONFIG" "CF_Token=saved-token"
  local check_output
  check_output="$(run_cmd cf-dns-check)"
  assert_contains "$check_output" "校验通过"
  teardown_env
}

test_save_cloudflare_credentials_with_special_chars() {
  setup_env
  unset CF_Token
  run_cmd install >/dev/null
  run_cmd set-cf-credentials --token 'token$with!special#chars' >/tmp/npmgr-cf-special.out
  assert_file_contains "$NPMGR_CF_CONFIG" 'CF_Token='
  local check_output
  check_output="$(run_cmd cf-dns-check)"
  assert_contains "$check_output" "校验通过"
  teardown_env
}

test_help_and_version_are_available() {
  setup_env
  local help_output
  local version_output
  help_output="$(run_cmd --help)"
  version_output="$(run_cmd version)"
  assert_contains "$help_output" "用法"
  assert_contains "$help_output" "add-http"
  assert_contains "$version_output" "nginx-proxy-manager.sh"
  teardown_env
}

test_user_facing_output_is_chinese() {
  setup_env
  local error_output
  if run_cmd show >/tmp/npmgr-show-missing.out 2>&1; then
    fail "expected show without rule name to fail"
  fi
  error_output="$(cat /tmp/npmgr-show-missing.out)"
  assert_contains "$error_output" "查看单条规则详情 需要规则名"
  assert_not_contains "$error_output" "[ERROR]"
  assert_not_contains "$error_output" "[WARN]"
  assert_not_contains "$error_output" "[INFO]"
  teardown_env
}

test_interactive_menu_is_chinese() {
  setup_env
  local menu_output
  menu_output="$(printf '0\n' | bash "$SCRIPT_PATH" 2>&1)"
  assert_contains "$menu_output" "Nginx 代理管理"
  assert_contains "$menu_output" "安装依赖并初始化环境"
  assert_contains "$menu_output" "添加 HTTP/HTTPS 反向代理"
  assert_contains "$menu_output" "设置 Cloudflare 凭证"
  assert_contains "$menu_output" "退出"
  assert_not_contains "$menu_output" "add-http"
  teardown_env
}

main() {
  [[ -x "$SCRIPT_PATH" ]] || fail "script not found: $SCRIPT_PATH"
  test_install_creates_layout
  test_install_does_not_break_http_without_stream_module
  test_add_http_removes_legacy_broken_stream_loader
  test_install_bootstraps_acme_without_crontab
  test_install_skips_unused_packages
  test_add_http_generates_rule_and_nginx_config
  test_http_domain_rules_can_share_https_port
  test_http_same_domain_same_port_is_rejected
  test_add_http_reports_cert_failure_and_keeps_rule
  test_add_http_reuses_existing_certificate_when_acme_skips_issue
  test_auto_dns_creates_cloudflare_record
  test_auto_dns_accepts_short_record_name
  test_auto_dns_failure_is_reported_and_rule_kept_disabled
  test_add_tcp_tls_generates_stream_config_and_cert_files
  test_add_tcp_requires_stream_module
  test_invalid_port_is_rejected
  test_delete_removes_rule_and_configs
  test_list_and_show_display_rule_details
  test_edit_and_enable_disable_work
  test_reload_renew_and_cf_check_work
  test_reload_removes_legacy_stream_include
  test_save_cloudflare_credentials_and_auto_load
  test_save_cloudflare_credentials_with_special_chars
  test_help_and_version_are_available
  test_user_facing_output_is_chinese
  test_interactive_menu_is_chinese
  echo "All tests passed"
}

main "$@"
