#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  frpc-gateway-install.sh
#  一键将本地端口发布为 <name>.<subdomain_host>
#  支持多实例并存，每个 name 独立 systemd 服务
#
#  用法:
#    sudo bash frpc-gateway-install.sh <server> <port> <token> <subdomain_host> <name> <local_port>
#
#  示例:
#    sudo bash frpc-gateway-install.sh 1.2.3.4 2001 <token> example.com myapp 3000
#    sudo bash frpc-gateway-install.sh 1.2.3.4 2001 <token> example.com myapp1 3001
#
#  管理:
#    bash frpc-gateway-install.sh --list
#    sudo bash frpc-gateway-install.sh --remove <name>
#    sudo bash frpc-gateway-install.sh --uninstall-all
# ============================================================

FRP_VERSION="0.61.1"

INSTALL_DIR="/usr/local/bin"
CONF_DIR="/etc/frpc-gateway"
FRPC_BIN="${INSTALL_DIR}/frpc-gateway"
SERVICE_PREFIX="frpc-gateway"

# --- 颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

ensure_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请使用 sudo 或 root 运行此脚本"
        exit 1
    fi
}

service_name() { echo "${SERVICE_PREFIX}@${1}"; }

# --- list ---
do_list() {
    if [[ ! -d "${CONF_DIR}" ]] || ! ls "${CONF_DIR}"/*.toml &>/dev/null; then
        info "当前没有任何已注册的代理"
        return
    fi
    echo ""
    printf "  ${CYAN}%-20s %-8s %-35s %s${NC}\n" "NAME" "PORT" "URL" "STATUS"
    printf "  %-20s %-8s %-35s %s\n" "----" "----" "---" "------"
    for conf in "${CONF_DIR}"/*.toml; do
        local name
        name="$(basename "${conf}" .toml)"
        local port
        port="$(grep 'localPort' "${conf}" | head -1 | awk '{print $NF}' || echo "?")"
        local subdomain
        subdomain="$(grep '^subdomain' "${conf}" | head -1 | sed 's/.*= *"\(.*\)"/\1/' || echo "${name}")"
        local domain
        domain="$(grep '^# subdomainHost' "${conf}" | head -1 | sed 's/^# subdomainHost = //' || echo "")"
        local url
        if [[ -n "${domain}" ]]; then
            url="https://${subdomain}.${domain}"
        else
            url="${subdomain} (domain unknown)"
        fi
        local svc
        svc="$(service_name "${name}")"
        local status
        if systemctl is-active --quiet "${svc}" 2>/dev/null; then
            status="${GREEN}running${NC}"
        else
            status="${RED}stopped${NC}"
        fi
        printf "  %-20s %-8s %-35s %b\n" "${name}" "${port}" "${url}" "${status}"
    done
    echo ""
}

# --- remove ---
do_remove() {
    local name="$1"
    local svc
    svc="$(service_name "${name}")"

    info "移除 ${name} ..."
    systemctl stop "${svc}" 2>/dev/null || true
    systemctl disable "${svc}" 2>/dev/null || true
    rm -f "${CONF_DIR}/${name}.toml"
    systemctl daemon-reload
    info "已移除 ${name}"

    if ! ls "${CONF_DIR}"/*.toml &>/dev/null; then
        warn "已无剩余代理，可运行 --uninstall-all 完全清理"
    fi
}

# --- uninstall-all ---
do_uninstall_all() {
    info "完全卸载 frpc-gateway ..."

    if [[ -d "${CONF_DIR}" ]]; then
        for conf in "${CONF_DIR}"/*.toml; do
            [[ -f "${conf}" ]] || continue
            local name
            name="$(basename "${conf}" .toml)"
            local svc
            svc="$(service_name "${name}")"
            systemctl stop "${svc}" 2>/dev/null || true
            systemctl disable "${svc}" 2>/dev/null || true
        done
    fi

    rm -f "/etc/systemd/system/${SERVICE_PREFIX}@.service"
    systemctl daemon-reload
    rm -f "${FRPC_BIN}"
    rm -rf "${CONF_DIR}"
    rm -f /var/log/frpc-gateway-*.log
    info "完全卸载完成"
}

# --- 路由子命令 ---
case "${1:-}" in
    --list|-l)
        do_list
        exit 0
        ;;
    --remove|-r)
        ensure_root
        [[ -z "${2:-}" ]] && { error "用法: $0 --remove <name>"; exit 1; }
        do_remove "$2"
        exit 0
        ;;
    --uninstall-all)
        ensure_root
        do_uninstall_all
        exit 0
        ;;
    --help|-h)
        echo "用法:"
        echo "  sudo $0 <server> <port> <token> <subdomain_host> <name> <local_port>"
        echo "                                  添加代理: name.subdomain_host → 127.0.0.1:local_port"
        echo "  $0 --list                       列出所有已注册代理"
        echo "  sudo $0 --remove <name>         移除指定代理"
        echo "  sudo $0 --uninstall-all         完全卸载"
        echo ""
        echo "参数:"
        echo "  server           frps 服务器地址 (IP 或域名)"
        echo "  port             frps 控制端口"
        echo "  token            frps auth token"
        echo "  subdomain_host   子域名主机 (例: example.com)"
        echo "  name             代理名称 (将作为子域名前缀)"
        echo "  local_port       本地要代理的端口"
        echo ""
        echo "示例:"
        echo "  sudo $0 1.2.3.4 2001 xxxxxxxx-xxxx example.com myapp 3000"
        echo "  → https://myapp.example.com → 127.0.0.1:3000"
        exit 0
        ;;
    -*)
        error "未知选项: $1"
        echo "运行 $0 --help 查看帮助"
        exit 1
        ;;
esac

# --- 添加代理 ---
if [[ $# -lt 6 ]]; then
    echo "用法: sudo $0 <server> <port> <token> <subdomain_host> <name> <local_port>"
    echo "  例: sudo $0 1.2.3.4 2001 xxxxxxxx-xxxx example.com myapp 3000"
    echo "      → https://myapp.example.com → 127.0.0.1:3000"
    echo ""
    echo "运行 $0 --help 查看更多命令"
    exit 1
fi

FRP_SERVER="$1"
FRP_SERVER_PORT="$2"
FRP_TOKEN="$3"
SUBDOMAIN_HOST="$4"
PROXY_NAME="$5"
LOCAL_PORT="$6"

if ! [[ "${FRP_SERVER_PORT}" =~ ^[0-9]+$ ]] || (( FRP_SERVER_PORT < 1 || FRP_SERVER_PORT > 65535 )); then
    error "服务器端口无效: ${FRP_SERVER_PORT}"
    exit 1
fi

if ! [[ "${LOCAL_PORT}" =~ ^[0-9]+$ ]] || (( LOCAL_PORT < 1 || LOCAL_PORT > 65535 )); then
    error "本地端口无效: ${LOCAL_PORT}"
    exit 1
fi

if ! [[ "${PROXY_NAME}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
    error "名称只能包含字母、数字和连字符，且不能以连字符开头或结尾: ${PROXY_NAME}"
    exit 1
fi

ensure_root

# --- 检测架构 ---
ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64)  FRP_ARCH="amd64" ;;
    aarch64) FRP_ARCH="arm64" ;;
    armv7l)  FRP_ARCH="arm"   ;;
    *)       error "不支持的架构: ${ARCH}"; exit 1 ;;
esac

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"

# --- 安装 frpc 二进制（共享，只装一次）---
NEED_DOWNLOAD=""
if [[ -f "${FRPC_BIN}" ]]; then
    CURRENT_VER="$("${FRPC_BIN}" --version 2>/dev/null || echo "unknown")"
    if [[ "${CURRENT_VER}" == "${FRP_VERSION}" ]]; then
        info "frpc-gateway v${FRP_VERSION} 已安装，跳过下载"
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
    cp "${TMP_DIR}/frp_${FRP_VERSION}_${OS}_${FRP_ARCH}/frpc" "${FRPC_BIN}"
    chmod +x "${FRPC_BIN}"
    info "已安装 frpc-gateway → ${FRPC_BIN}"
fi

# --- 写配置（每个 name 独立文件）---
mkdir -p "${CONF_DIR}"

if [[ -f "${CONF_DIR}/${PROXY_NAME}.toml" ]]; then
    warn "${PROXY_NAME} 已存在，将覆盖配置并重启"
fi

cat > "${CONF_DIR}/${PROXY_NAME}.toml" <<EOF
# subdomainHost = ${SUBDOMAIN_HOST}
serverAddr = "${FRP_SERVER}"
serverPort = ${FRP_SERVER_PORT}

auth.method = "token"
auth.token = "${FRP_TOKEN}"

transport.tls.enable = true

log.to = "/var/log/frpc-gateway-${PROXY_NAME}.log"
log.level = "info"
log.maxDays = 7

[[proxies]]
name = "${PROXY_NAME}"
type = "http"
localIP = "127.0.0.1"
localPort = ${LOCAL_PORT}
subdomain = "${PROXY_NAME}"
EOF

info "配置已写入 ${CONF_DIR}/${PROXY_NAME}.toml"

# --- 创建 systemd 模板单元（只需写一次）---
TEMPLATE="/etc/systemd/system/${SERVICE_PREFIX}@.service"
cat > "${TEMPLATE}" <<EOF
[Unit]
Description=frpc-gateway - %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${FRPC_BIN} -c ${CONF_DIR}/%i.toml
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

SVC="$(service_name "${PROXY_NAME}")"

systemctl daemon-reload
systemctl enable "${SVC}"
systemctl restart "${SVC}"

sleep 1

if systemctl is-active --quiet "${SVC}"; then
    info "frpc-gateway 启动成功！"
    echo ""
    info "  https://${PROXY_NAME}.${SUBDOMAIN_HOST} → 127.0.0.1:${LOCAL_PORT}"
    echo ""
    info "  查看状态:  systemctl status ${SVC}"
    info "  查看日志:  journalctl -u ${SVC} -f"
    info "  列出所有:  $0 --list"
    info "  移除此条:  sudo $0 --remove ${PROXY_NAME}"
    info "  完全卸载:  sudo $0 --uninstall-all"
else
    error "frpc-gateway 启动失败"
    journalctl -u "${SVC}" --no-pager -n 20
    exit 1
fi
