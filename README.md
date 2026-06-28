# nginx-proxy-manager.sh

一个面向 `Debian 13` 的 Bash 工具，用来自动管理 `Nginx` 反向代理、`stream TCP` 转发、`Cloudflare DNS` 和 `acme.sh` 证书申请。

## 一键运行

适合在全新 `Debian 13` 服务器上直接执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wzdyf1992/nginx-proxy-manager/main/nginx-proxy-manager.sh) install
```

这个安装流程会自动补齐 `cron`，并在 `acme.sh` 因 `crontab` 检查失败时自动回退到 `--force` 安装。

初始化完成后，可继续进入交互菜单：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wzdyf1992/nginx-proxy-manager/main/nginx-proxy-manager.sh)
```

## 功能

- 交互式菜单 + 命令行两种使用方式
- HTTP/HTTPS 站点反代
- TCP 端口转发
- TCP 单端口 TLS 终止
- Cloudflare API Token 校验
- 可选自动创建/更新 Cloudflare DNS 记录
- 使用 `acme.sh + dns_cf` 自动申请和续期证书
- 规则增删查改、启停、Nginx 重载

## 目录约定

- 规则文件：`/etc/nginx-proxy-manager/rules/`
- 证书文件：`/etc/nginx-proxy-manager/certs/`
- 运行时文件：`/etc/nginx-proxy-manager/runtime/`
- HTTP 配置：`/etc/nginx/sites-available/`、`/etc/nginx/sites-enabled/`
- TCP 配置：`/etc/nginx/streams-available/`、`/etc/nginx/streams-enabled/`

## 依赖

- `nginx`
- `curl`
- `jq`
- `cron`
- `Debian 13`

脚本的 `install` 命令会自动安装必要依赖，并自动安装 `acme.sh`，所以第一次使用不需要你手动先装 `acme.sh`。

## 快速开始

先给脚本执行权限：

```bash
chmod +x ./nginx-proxy-manager.sh
```

初始化环境：

```bash
sudo ./nginx-proxy-manager.sh install
```

## Cloudflare 凭据

证书申请和自动 DNS 需要先设置：

```bash
export CF_Token="你的 Cloudflare API Token"
```

建议 Token 至少有：

- `Zone:DNS:Edit`
- `Zone:Zone:Read`

你也可以先检查 Token：

```bash
sudo ./nginx-proxy-manager.sh cf-dns-check
```

## 常用命令

查看帮助：

```bash
./nginx-proxy-manager.sh --help
```

直接进入交互菜单：

```bash
sudo ./nginx-proxy-manager.sh
```

菜单界面和提示信息现在默认全部为中文。

### 1）添加 HTTP/HTTPS 反代

```bash
sudo ./nginx-proxy-manager.sh add-http \
  --name blog \
  --domain blog.example.com \
  --listen 443 \
  --upstream-host 127.0.0.1 \
  --upstream-port 3000 \
  --upstream-proto http \
  --https on \
  --auto-dns on \
  --cf-zone example.com \
  --cf-record-name blog.example.com
```

### 2）添加纯 TCP 转发

```bash
sudo ./nginx-proxy-manager.sh add-tcp \
  --name redis-proxy \
  --listen 6380 \
  --upstream-host 192.168.1.20 \
  --upstream-port 6379 \
  --tls-mode passthrough
```

### 3）添加 TCP TLS 终止

```bash
sudo ./nginx-proxy-manager.sh add-tcp \
  --name ssh-tls \
  --listen 9443 \
  --upstream-host 127.0.0.1 \
  --upstream-port 22 \
  --tls-mode terminate \
  --domain ssh.example.com
```

### 4）查看规则

```bash
sudo ./nginx-proxy-manager.sh list
sudo ./nginx-proxy-manager.sh show blog
```

### 5）修改规则

`edit` 复用新增参数，只写你要改的字段：

```bash
sudo ./nginx-proxy-manager.sh edit blog \
  --upstream-port 3001 \
  --auto-dns off
```

### 6）启用/禁用/删除

```bash
sudo ./nginx-proxy-manager.sh disable blog
sudo ./nginx-proxy-manager.sh enable blog
sudo ./nginx-proxy-manager.sh delete blog
```

### 7）证书续期

```bash
sudo ./nginx-proxy-manager.sh renew-certs
```

## 规则文件格式

每条规则都会单独保存成一个 `.conf` 元数据文件，例如：

```ini
RULE_NAME=blog
RULE_TYPE=http
SERVER_NAME=blog.example.com
LISTEN_PORT=443
UPSTREAM_HOST=127.0.0.1
UPSTREAM_PORT=3000
UPSTREAM_PROTO=http
ENABLE_HTTPS=on
AUTO_DNS=on
CF_ZONE=example.com
CF_RECORD_NAME=blog.example.com
CERT_MODE=dns_cf
ENABLED=on
```

## 当前边界

- HTTP 证书申请必须基于域名
- TCP TLS 终止只支持“单监听端口 + 单证书 + 单 upstream”
- 暂不支持 TCP 基于 `SNI` 的多路复用
- 当前只保证 `Debian 13` 兼容

## 测试

本项目带了一个 Bash 行为测试：

```bash
bash tests/test_nginx_proxy_manager.sh
```
