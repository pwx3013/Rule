#!/bin/bash
# Trojan (TLS + WebSocket) 一键部署脚本 —— sing-box Docker 版
# 用法: bash deploy-trojan-ws.sh
# 环境变量覆盖默认值:
#   TROJAN_PORT  监听 TCP 端口（默认 34443）
#   WS_PATH      WebSocket 路径（默认 /trojan）
#   SNI          TLS SNI / 证书 CN（默认 www.bing.com）
#   PASSWORD     Trojan 密码（默认随机生成 32 位 hex，存 meta.env 复用）
set -euo pipefail

DIR="/opt/trojan-ws"
CONF="$DIR/conf"
META="$CONF/meta.env"
IMAGE="ghcr.io/sagernet/sing-box:v1.14.2"

command -v docker >/dev/null || { echo "未检测到 docker，请先安装"; exit 1; }
mkdir -p "$CONF"

# ---- 读旧凭据（重复运行复用）----
if [ -f "$META" ]; then
  # shellcheck disable=SC1090
  source "$META"
fi

TROJAN_PORT="${TROJAN_PORT:-${TROJAN_PORT_SAVED:-34443}}"
WS_PATH="${WS_PATH:-${WS_PATH_SAVED:-/trojan}}"
SNI="${SNI:-${SNI_SAVED:-www.bing.com}}"
PASSWORD="${PASSWORD:-${PASSWORD_SAVED:-$(openssl rand -hex 16)}}"

# ---- 自签证书（SNI 变了就重签）----
if [ ! -f "$CONF/cert.pem" ] || [ "${SNI}" != "${SNI_SAVED:-}" ]; then
  echo "生成自签证书 (CN=${SNI})…"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$CONF/key.pem" -out "$CONF/cert.pem" \
    -days 3650 -nodes -subj "/CN=${SNI}" 2>/dev/null
fi

# ---- 写 sing-box 配置 ----
cat > "$CONF/config.json" <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "trojan",
      "tag": "trojan-in",
      "listen": "::",
      "listen_port": ${TROJAN_PORT},
      "users": [{ "password": "${PASSWORD}" }],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/key.pem"
      },
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}"
      }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF
chmod 600 "$CONF/config.json"

# ---- 回写 meta.env ----
cat > "$META" <<EOF
TROJAN_PORT_SAVED=${TROJAN_PORT}
WS_PATH_SAVED=${WS_PATH}
SNI_SAVED=${SNI}
PASSWORD_SAVED=${PASSWORD}
EOF
chmod 600 "$META"

# ---- 校验配置 ----
echo "校验配置…"
docker run --rm -v "$CONF:/etc/sing-box" "$IMAGE" check -c /etc/sing-box/config.json

# ---- 启动容器 ----
docker rm -f trojan-ws 2>/dev/null || true
docker run -d --name trojan-ws --restart unless-stopped --network host \
  -v "$CONF:/etc/sing-box" \
  "$IMAGE" run -c /etc/sing-box/config.json
sleep 2
docker ps --filter name=trojan-ws --format '{{.Status}}' | grep -qi up \
  || { docker logs trojan-ws --tail 20; echo "容器未正常运行"; exit 1; }

# ---- 放行防火墙 ----
if command -v iptables >/dev/null 2>&1; then
  iptables -C INPUT -p tcp --dport "$TROJAN_PORT" -j ACCEPT 2>/dev/null \
    || iptables -I INPUT -p tcp --dport "$TROJAN_PORT" -j ACCEPT 2>/dev/null || true
fi

HOST="$(curl -fsSL --max-time 8 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"

echo ""
echo "================ 部署完成 ================"
echo "服务器: ${HOST}:${TROJAN_PORT}"
echo "密码: ${PASSWORD}"
echo "SNI: ${SNI}（自签证书，客户端需跳过证书验证）"
echo "WS 路径: ${WS_PATH}"
echo ""
echo "---- Surge ----"
echo "MB-TROJAN-WS = trojan, ${HOST}, ${TROJAN_PORT}, password=${PASSWORD}, sni=${SNI}, skip-cert-verify=true, ws=true, ws-path=${WS_PATH}"
echo ""
echo "---- Egern / 通用链接 ----"
echo "trojan://${PASSWORD}@${HOST}:${TROJAN_PORT}?sni=${SNI}&allowInsecure=1&type=ws&path=${WS_PATH}#MB-TROJAN-WS"
echo ""
echo "配置目录: $CONF（重跑脚本会复用密码与端口）"
