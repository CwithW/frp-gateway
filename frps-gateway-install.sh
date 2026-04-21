#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  frps-gateway-install.sh
#  在公网服务器上部署 frps-gateway 服务端
#
#  用法:
#    sudo bash frps-gateway-install.sh <subdomain_host> [bind_port] [vhost_http_port]
#
#  示例:
#    sudo bash frps-gateway-install.sh example.com
#    sudo bash frps-gateway-install.sh example.com 2001 2002
#
#  这将:
#    1. 下载 frp 并安装 frps 到 /usr/local/bin/frps-gateway
#    2. 生成随机 auth token
#    3. 创建配置 /etc/frps-gateway/frps.toml
#    4. 创建并启动 systemd 服务 frps-gateway
#
#  部署后你需要:
#    - 配置 DNS: *.<subdomain_host> → 本机 IP
#    - 配置反向代理 (Caddy/Nginx) 将 HTTP 请求转发到 vhost_http_port
#
#  卸载:
#    sudo bash frps-gateway-install.sh --uninstall
# ============================================================

FRP_VERSION="0.61.1"

DEFAULT_BIND_PORT=2001
DEFAULT_VHOST_HTTP_PORT=2002
DEFAULT_DASHBOARD_PORT=2003

INSTALL_DIR="/usr/local/bin"
CONF_DIR="/etc/frps-gateway"
FRPS_BIN="${INSTALL_DIR}/frps-gateway"
SERVICE_NAME="frps-gateway"

# --- 颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- 卸载 ---
if [[ "${1:-}" == "--uninstall" ]]; then
    if [[ $EUID -ne 0 ]]; then
        error "请使用 sudo 或 root 运行"
        exit 1
    fi
    info "卸载 frps-gateway ..."
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
    rm -f "${FRPS_BIN}"
    # 保留配置目录，让用户确认后手动删除
    warn "配置目录 ${CONF_DIR} 已保留（含 auth token），如需删除请手动: rm -rf ${CONF_DIR}"
    info "卸载完成"
    exit 0
fi

# --- 参数检查 ---
if [[ $# -lt 1 ]]; then
    echo "用法: sudo $0 <subdomain_host> [bind_port] [vhost_http_port]"
    echo ""
    echo "参数:"
    echo "  subdomain_host    子域名主机 (例: example.com → *.example.com)"
    echo "  bind_port         frp 控制端口 (默认: ${DEFAULT_BIND_PORT})"
    echo "  vhost_http_port   HTTP vhost 端口 (默认: ${DEFAULT_VHOST_HTTP_PORT}，绑定 127.0.0.1)"
    echo ""
    echo "示例:"
    echo "  sudo $0 example.com"
    echo "  sudo $0 example.com 7000 7080"
    echo ""
    echo "卸载:"
    echo "  sudo $0 --uninstall"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    error "请使用 sudo 或 root 运行此脚本"
    exit 1
fi

SUBDOMAIN_HOST="$1"
BIND_PORT="${2:-${DEFAULT_BIND_PORT}}"
VHOST_HTTP_PORT="${3:-${DEFAULT_VHOST_HTTP_PORT}}"
DASHBOARD_PORT="${DEFAULT_DASHBOARD_PORT}"

# --- 生成 auth token ---
generate_token() {
    if command -v uuidgen &>/dev/null; then
        uuidgen
    elif [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        head -c 32 /dev/urandom | xxd -p | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\).*/\1-\2-\3-\4-\5/'
    fi
}

# --- 检测架构 ---
ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64)  FRP_ARCH="amd64" ;;
    aarch64) FRP_ARCH="arm64" ;;
    armv7l)  FRP_ARCH="arm"   ;;
    *)       error "不支持的架构: ${ARCH}"; exit 1 ;;
esac

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"

# --- 安装 frps 二进制 ---
NEED_DOWNLOAD=""
if [[ -f "${FRPS_BIN}" ]]; then
    CURRENT_VER="$("${FRPS_BIN}" --version 2>/dev/null || echo "unknown")"
    if [[ "${CURRENT_VER}" == "${FRP_VERSION}" ]]; then
        info "frps-gateway v${FRP_VERSION} 已安装，跳过下载"
    else
        info "当前版本 ${CURRENT_VER}，升级到 v${FRP_VERSION} ..."
        NEED_DOWNLOAD=1
    fi
else
    NEED_DOWNLOAD=1
fi

if [[ "${NEED_DOWNLOAD}" == "1" ]]; then
    TARBALL="frp_${FRP_VERSION}_${OS}_${FRP_ARCH}.tar.gz"
    URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${TARBALL}"
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "${TMP_DIR}"' EXIT

    info "下载 frp v${FRP_VERSION} (${FRP_ARCH}) ..."
    if command -v wget &>/dev/null; then
        wget -q --show-progress -O "${TMP_DIR}/${TARBALL}" "${URL}"
    elif command -v curl &>/dev/null; then
        curl -fSL -o "${TMP_DIR}/${TARBALL}" "${URL}"
    else
        error "需要 wget 或 curl"
        exit 1
    fi

    tar xzf "${TMP_DIR}/${TARBALL}" -C "${TMP_DIR}"
    cp "${TMP_DIR}/frp_${FRP_VERSION}_${OS}_${FRP_ARCH}/frps" "${FRPS_BIN}"
    chmod +x "${FRPS_BIN}"
    info "已安装 frps-gateway → ${FRPS_BIN}"
fi

# --- 写配置 ---
mkdir -p "${CONF_DIR}"

# 如果已有配置，保留现有 token
if [[ -f "${CONF_DIR}/frps.toml" ]]; then
    EXISTING_TOKEN="$(grep 'auth.token' "${CONF_DIR}/frps.toml" | head -1 | sed 's/.*= *"\(.*\)"/\1/')"
    if [[ -n "${EXISTING_TOKEN}" ]]; then
        AUTH_TOKEN="${EXISTING_TOKEN}"
        warn "检测到已有配置，保留现有 auth token"
    else
        AUTH_TOKEN="$(generate_token)"
    fi
else
    AUTH_TOKEN="$(generate_token)"
fi

# --- 创建自定义 404 页面（隐藏 frp 指纹）---
cat > "${CONF_DIR}/404.html" <<'HTMLEOF'
<!DOCTYPE html><html><head><title>404 Not Found</title></head>
<body><center><h1>404 Not Found</h1></center><hr><center>nginx</center></body></html>
HTMLEOF

cat > "${CONF_DIR}/frps.toml" <<EOF
bindAddr = "0.0.0.0"
bindPort = ${BIND_PORT}

proxyBindAddr = "127.0.0.1"
vhostHTTPPort = ${VHOST_HTTP_PORT}

webServer.addr = "127.0.0.1"
webServer.port = ${DASHBOARD_PORT}

transport.maxPoolCount = 10
transport.tls.force = true

auth.method = "token"
auth.token = "${AUTH_TOKEN}"

subDomainHost = "${SUBDOMAIN_HOST}"

custom404Page = "${CONF_DIR}/404.html"

log.to = "/var/log/frps-gateway.log"
log.level = "info"
log.maxDays = 7
EOF

info "配置已写入 ${CONF_DIR}/frps.toml"

# --- 创建 systemd 服务 ---
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=frps-gateway - FRP Server for *.${SUBDOMAIN_HOST}
After=network.target

[Service]
Type=simple
ExecStart=${FRPS_BIN} -c ${CONF_DIR}/frps.toml
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

sleep 1

if systemctl is-active --quiet "${SERVICE_NAME}"; then
    info "frps-gateway 启动成功！"
    echo ""
    echo -e "  ${CYAN}========================================${NC}"
    echo -e "  ${CYAN}  frps-gateway 部署信息${NC}"
    echo -e "  ${CYAN}========================================${NC}"
    echo ""
    echo -e "  子域名主机:    ${GREEN}*.${SUBDOMAIN_HOST}${NC}"
    echo -e "  控制端口:      ${GREEN}0.0.0.0:${BIND_PORT}${NC}"
    echo -e "  HTTP vhost:    ${GREEN}127.0.0.1:${VHOST_HTTP_PORT}${NC}"
    echo -e "  Dashboard:     ${GREEN}127.0.0.1:${DASHBOARD_PORT}${NC}"
    echo -e "  Auth Token:    ${GREEN}${AUTH_TOKEN}${NC}"
    echo -e "  TLS:           ${GREEN}强制开启${NC}"
    echo ""
    echo -e "  ${YELLOW}请保存以上信息，客户端连接时需要 auth token。${NC}"
    echo ""
    echo -e "  ${CYAN}接下来你需要:${NC}"
    echo -e "  1. 配置 DNS: *.${SUBDOMAIN_HOST} → 本机公网 IP"
    echo -e "  2. 配置反向代理，将 *.${SUBDOMAIN_HOST} 的 HTTP 请求转发到 127.0.0.1:${VHOST_HTTP_PORT}"
    echo ""
    echo -e "  ${CYAN}Caddy 示例 (追加到 Caddyfile):${NC}"
    echo ""
    echo "    *.${SUBDOMAIN_HOST} {"
    echo "        reverse_proxy 127.0.0.1:${VHOST_HTTP_PORT} {"
    echo "            header_up Host {host}"
    echo "        }"
    echo "    }"
    echo ""
    echo -e "  ${CYAN}客户端安装命令:${NC}"
    echo ""
    echo "    sudo bash frpc-gateway-install.sh <服务器IP> ${BIND_PORT} ${AUTH_TOKEN} ${SUBDOMAIN_HOST} <name> <port>"
    echo ""
    info "  查看状态:  systemctl status ${SERVICE_NAME}"
    info "  查看日志:  journalctl -u ${SERVICE_NAME} -f"
    info "  卸载:      sudo $0 --uninstall"
else
    error "frps-gateway 启动失败"
    journalctl -u "${SERVICE_NAME}" --no-pager -n 20
    exit 1
fi
