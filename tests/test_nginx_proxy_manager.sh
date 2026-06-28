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

assert_file_contains() {
  local path="$1"
  local needle="$2"
  [[ -f "$path" ]] || fail "expected file to exist: $path"
  grep -F "$needle" "$path" >/dev/null || fail "expected $path to contain: $needle"
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
  TMP_ROOT="$(mktemp -d)"
  export NPMGR_TEST_MODE=1
  export NPMGR_BASE_DIR="$TMP_ROOT/etc/nginx-proxy-manager"
  export NPMGR_NGINX_ETC="$TMP_ROOT/etc/nginx"
  export NPMGR_ACME_HOME="$TMP_ROOT/acme"
  export NPMGR_SYSTEMCTL_BIN="$TMP_ROOT/bin/systemctl"
  export CF_Token="test-token"
  mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/etc/nginx/modules-enabled" "$TMP_ROOT/etc/nginx/conf.d"
  cat >"$TMP_ROOT/bin/nginx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-t" ]]; then
  if grep -R "INVALID_DIRECTIVE" "${NPMGR_NGINX_ETC}" >/dev/null 2>&1; then
    echo "nginx: configuration test failed" >&2
    exit 1
  fi
  echo "nginx: configuration file ${NPMGR_NGINX_ETC}/nginx.conf test is successful"
  exit 0
fi
echo "fake nginx $*"
EOF
  cat >"$TMP_ROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"${NPMGR_BASE_DIR}/runtime/systemctl.log"
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
  echo "${MOCK_CURL_RESPONSE:-{\"success\":true,\"result\":[]}}"
fi
EOF
  cat >"$TMP_ROOT/bin/jq" <<'EOF'
#!/usr/bin/env python3
import json, sys
data = json.load(sys.stdin)
expr = sys.argv[1]
if expr == '.success':
    print('true' if data.get('success') else 'false')
elif expr == '.result[0].id // empty':
    result = data.get('result') or []
    print(result[0].get('id', '') if result else '')
elif expr == '.result[0].content // empty':
    result = data.get('result') or []
    print(result[0].get('content', '') if result else '')
else:
    raise SystemExit(1)
EOF
  if [[ "$with_acme" == "1" ]]; then
    cat >"$TMP_ROOT/bin/acme.sh" <<'EOF'
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
EOF
  fi
  chmod +x "$TMP_ROOT/bin/nginx" "$TMP_ROOT/bin/systemctl" "$TMP_ROOT/bin/curl" "$TMP_ROOT/bin/jq"
  if [[ "$with_acme" == "1" ]]; then
    chmod +x "$TMP_ROOT/bin/acme.sh"
  fi
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
  assert_file_contains "$NPMGR_NGINX_ETC/modules-enabled/50-mod-stream.conf" "stream"
  teardown_env
}

test_install_bootstraps_acme_without_crontab() {
  setup_env 0
  run_cmd install >/tmp/npmgr-install-acme.out
  assert_exists "$NPMGR_ACME_HOME/acme.sh"
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
  assert_file_contains "$NPMGR_NGINX_ETC/sites-available/npmgr-blog.conf" "server_name blog.example.com;"
  assert_file_contains "$NPMGR_NGINX_ETC/sites-available/npmgr-blog.conf" "proxy_pass http://127.0.0.1:3000;"
  assert_symlink_target "$NPMGR_NGINX_ETC/sites-enabled/npmgr-blog.conf" "$NPMGR_NGINX_ETC/sites-available/npmgr-blog.conf"
  assert_file_contains "$NPMGR_BASE_DIR/runtime/systemctl.log" "reload nginx"
  teardown_env
}

test_add_tcp_tls_generates_stream_config_and_cert_files() {
  setup_env
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

main() {
  [[ -x "$SCRIPT_PATH" ]] || fail "script not found: $SCRIPT_PATH"
  test_install_creates_layout
  test_install_bootstraps_acme_without_crontab
  test_add_http_generates_rule_and_nginx_config
  test_add_tcp_tls_generates_stream_config_and_cert_files
  test_invalid_port_is_rejected
  test_delete_removes_rule_and_configs
  test_list_and_show_display_rule_details
  echo "All tests passed"
}

main "$@"
