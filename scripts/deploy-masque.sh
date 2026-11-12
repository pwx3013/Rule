#!/bin/bash
# 一键部署 zenith-ent/masque-server (MASQUE over HTTP/3, Rust 实现)
# 仓库: https://github.com/zenith-ent/masque-server
#
# 用法 (在 VPS 上以 root 运行):
#   sudo bash deploy-masque.sh                  # 默认端口 443
#   sudo bash deploy-masque.sh 8443             # 自定义端口(位置参数)
#   MASQUE_PORT=8443 sudo bash deploy-masque.sh # 自定义端口(环境变量)
#
# 可选环境变量:
#   MASQUE_PORT      监听端口, 默认 443
#   MASQUE_VERSION   指定版本, 如 v0.14.22 (默认自动取最新 Release)
#   MASQUE_USER      认证用户名, 默认 masque
#   MASQUE_PASSWORD  认证密码, 默认随机生成 (16 字节 hex)
#   MASQUE_TLS_NAME  证书用的域名或公网 IP, 默认自动检测公网 IP
#   MASQUE_TRANSPORT http3 (默认) 或 http2
#
# 说明:
# - systemd 的机器直接调用官方 install.sh (支持 MASQUE_LISTEN_PORT 自定义端口);
#   Alpine/OpenRC 的机器走手动安装分支 (二进制 + 配置 + OpenRC 服务)。
# - 证书为自签, 客户端须开 skip-cert-verify。
# - 客户端: Surge iOS 5.22.0+/Mac 6.9.0+ 支持 MASQUE; Egern 不支持。
# - 云厂商安全组须放行 UDP <端口> (Oracle/AWS 控制台里开)。
set -euo pipefail

REPO="zenith-ent/masque-server"
FALLBACK_VERSION="v0.14.22"
BIN_NAME="masque-server"

# ---- 0. root 检查 ----
[[ $EUID -ne 0 ]] && { echo "请用 root 运行: sudo bash $0" >&2; exit 1; }

# ---- 1. 端口 (位置参数优先, 其次环境变量, 默认 443) ----
PORT="${1:-${MASQUE_PORT:-443}}"
case "$PORT" in
    ""|*[!0-9]*) echo "端口必须是 1-65535 的数字: $PORT" >&2; exit 1 ;;
esac
[[ "$PORT" -lt 1 || "$PORT" -gt 65535 ]] && { echo "端口必须在 1-65535 之间: $PORT" >&2; exit 1; }

# ---- 2. 已安装检查 ----
if [[ -f /etc/masque/masque.toml ]]; then
    echo "检测到已安装 (/etc/masque/masque.toml 存在)。如需重装请先备份并删除配置:"
    echo "  mv /etc/masque/masque.toml /etc/masque/masque.toml.bak"
    echo "改端口可用官方命令加监听器:"
    echo "  masque-server --config /etc/masque/masque.toml add-listener"
    exit 1
fi

# ---- 3. 架构 + init 系统 ----
case "$(uname -m)" in
    x86_64|amd64) ARCH="x86_64" ;;
    aarch64|arm64) ARCH="aarch64" ;;
    *) echo "不支持的架构: $(uname -m) (仅 x86_64/aarch64)" >&2; exit 1 ;;
esac
if command -v systemctl >/dev/null 2>&1; then
    INIT="systemd"
elif command -v rc-service >/dev/null 2>&1; then
    INIT="openrc"
else
    echo "需要 systemd 或 OpenRC (systemctl/rc-service 均未找到)" >&2; exit 1
fi

# ---- 4. 依赖 ----
DL=""
command -v curl >/dev/null 2>&1 && DL="curl -fsSL"
[[ -z "$DL" ]] && command -v wget >/dev/null 2>&1 && DL="wget -qO-"
[[ -z "$DL" ]] && { echo "需要 curl 或 wget" >&2; exit 1; }
for t in openssl tar sha256sum; do
    command -v "$t" >/dev/null 2>&1 || { echo "需要 $t, 请先安装" >&2; exit 1; }
done

# ---- 5. 公网 IP (证书 SAN 用) ----
TLS_NAME="${MASQUE_TLS_NAME:-}"
PUB_IP=""
if [[ -z "$TLS_NAME" ]]; then
    PUB_IP=$(curl -s --max-time 8 https://one.one.one.one/cdn-cgi/trace 2>/dev/null | grep '^ip=' | cut -d= -f2 || true)
    [[ -z "$PUB_IP" ]] && PUB_IP=$(curl -s --max-time 8 ifconfig.me 2>/dev/null || true)
    [[ -z "$PUB_IP" ]] && { echo "检测公网 IP 失败, 请用 MASQUE_TLS_NAME=域名或IP 指定" >&2; exit 1; }
    TLS_NAME="$PUB_IP"
fi

# ---- 6. 版本 ----
VERSION="${MASQUE_VERSION:-}"
if [[ -z "$VERSION" ]]; then
    VERSION=$(curl -s --max-time 15 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)
    [[ -z "$VERSION" ]] && VERSION="$FALLBACK_VERSION"
fi
echo "部署 $REPO $VERSION ($ARCH), 端口 UDP $PORT, init: $INIT"

# ---- 7. 下载 + SHA 校验 ----
TARBALL="masque-${VERSION}-linux-${ARCH}.tar.gz"
BASE_URL="https://github.com/$REPO/releases/download/$VERSION"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"
echo "下载 $TARBALL ..."
if [[ "$DL" == curl* ]]; then
    curl -fsSL --max-time 120 -o "$TARBALL" "$BASE_URL/$TARBALL"
    curl -fsSL --max-time 30 -o "$TARBALL.sha256" "$BASE_URL/$TARBALL.sha256" || true
else
    wget -q --timeout=120 -O "$TARBALL" "$BASE_URL/$TARBALL"
    wget -q --timeout=30 -O "$TARBALL.sha256" "$BASE_URL/$TARBALL.sha256" || true
fi
if [[ -s "$TARBALL.sha256" ]]; then
    EXPECTED=$(awk '{print $1}' "$TARBALL.sha256")
    ACTUAL=$(sha256sum "$TARBALL" | awk '{print $1}')
    [[ "$EXPECTED" == "$ACTUAL" ]] || { echo "SHA-256 校验失败, 停止安装" >&2; exit 1; }
    echo "SHA-256 校验通过"
else
    echo "警告: 未能下载 .sha256 文件, 跳过校验 (已走 HTTPS)"
fi
tar xzf "$TARBALL"
PKG_DIR="$WORKDIR/${TARBALL%.tar.gz}"
[[ -x "$PKG_DIR/bin/$BIN_NAME" ]] || { echo "解压后未找到 bin/$BIN_NAME" >&2; exit 1; }

# ---- 8. 认证凭据 (VPS 现生成, 不进仓库) ----
AUTH_USER="${MASQUE_USER:-masque}"
AUTH_PASS="${MASQUE_PASSWORD:-$(openssl rand -hex 16)}"
case "$AUTH_USER" in
    ""|*[!A-Za-z0-9._-]*) echo "用户名只允许字母/数字/./_/-: $AUTH_USER" >&2; exit 1 ;;
esac
TRANSPORT="${MASQUE_TRANSPORT:-http3}"
[[ "$TRANSPORT" != http3 && "$TRANSPORT" != http2 ]] && { echo "MASQUE_TRANSPORT 只能是 http3 或 http2" >&2; exit 1; }

# ---- 9. 安装 ----
if [[ "$INIT" == systemd ]]; then
    # 调用官方 install.sh (非交互: 全部用环境变量传入)
    MASQUE_LISTEN_PORT="$PORT" \
    MASQUE_TLS_MODE=self_signed \
    MASQUE_TLS_NAME="$TLS_NAME" \
    MASQUE_AUTH_MODE=basic \
    MASQUE_AUTH_USERNAME="$AUTH_USER" \
    MASQUE_AUTH_PASSWORD="$AUTH_PASS" \
    MASQUE_TRANSPORT="$TRANSPORT" \
    MASQUE_START_SERVICE=1 \
    MASQUE_PRINT_SECRETS=1 \
    sh "$PKG_DIR/install.sh"
else
    # ---- OpenRC (Alpine) 手动安装分支 ----
    install -m 0755 "$PKG_DIR/bin/$BIN_NAME" /usr/local/bin/$BIN_NAME
    [[ -x "$PKG_DIR/bin/masque-probe" ]] && install -m 0755 "$PKG_DIR/bin/masque-probe" /usr/local/bin/masque-probe
    mkdir -p /etc/masque/certs
    case "$TLS_NAME" in
        *[!0-9.]*) SAN="DNS:$TLS_NAME" ;;
        *) SAN="IP:$TLS_NAME" ;;
    esac
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
        -days 365 -subj "/CN=$(printf '%.64s' "$TLS_NAME")" -addext "subjectAltName=$SAN" \
        -keyout /etc/masque/certs/server.key -out /etc/masque/certs/server.crt >/dev/null 2>&1
    chmod 600 /etc/masque/certs/server.key
    HASH=$(printf '%s' "$AUTH_PASS" | /usr/local/bin/$BIN_NAME hash-password)
    cp "$PKG_DIR/config/masque.toml" /etc/masque/masque.toml
    sed -i \
        -e "s|^listen_addr = \"0.0.0.0:443\"$|listen_addr = \"0.0.0.0:$PORT\"|" \
        -e "s|__MASQUE_AUTH_USERNAME__|$AUTH_USER|" \
        -e "s|__MASQUE_AUTH_PASSWORD_HASH__|$HASH|" \
        /etc/masque/masque.toml
    grep -q "__MASQUE_AUTH_" /etc/masque/masque.toml && { echo "配置写入失败: 占位符未替换" >&2; exit 1; }
    /usr/local/bin/$BIN_NAME --config /etc/masque/masque.toml check-config || { echo "配置校验失败" >&2; exit 1; }
    cat > /etc/init.d/masque <<'EOF'
#!/sbin/openrc-run
description="MASQUE HTTP/2 and HTTP/3 proxy server"
command="/usr/local/bin/masque-server"
command_args="--config /etc/masque/masque.toml"
command_background=true
pidfile="/run/masque.pid"

depend() {
    need net
    after firewall
}
EOF
    chmod +x /etc/init.d/masque
    rc-update add masque default >/dev/null 2>&1
    rc-service masque start
fi

# ---- 10. 自检 + 输出 ----
echo
if [[ "$INIT" == systemd ]]; then
    systemctl is-active --quiet masque && echo "服务状态: masque running" || echo "警告: masque 服务未运行, 查 systemctl status masque"
else
    rc-service masque status | head -2
fi
echo
echo "================ MASQUE 已部署 ================"
echo "服务器 : $TLS_NAME"
echo "端口   : $PORT (UDP, HTTP/3)"
echo "用户名 : $AUTH_USER"
echo "密码   : $AUTH_PASS"
echo "         (密码只显示这一次, 请保存好)"
echo
echo "Surge 配置 (自签证书, 须开 skip-cert-verify):"
echo "Masque = masque, $TLS_NAME, $PORT, username=$AUTH_USER, password=$AUTH_PASS, skip-cert-verify=true"
echo
echo "测试 (需 masque-probe):"
echo "printf '%s' '$AUTH_PASS' | masque-probe $TLS_NAME:$PORT --username $AUTH_USER --password-stdin"
echo
echo "注意:"
echo "- 云厂商安全组须放行 UDP $PORT (Oracle/AWS 控制台里开)"
echo "- Surge iOS 5.22.0+/Mac 6.9.0+ 才支持 MASQUE; Egern 不支持"
echo "- 改密码: masque-server --config /etc/masque/masque.toml set-password --username $AUTH_USER"
echo "- 改端口: masque-server --config /etc/masque/masque.toml add-listener (再重启服务)"
