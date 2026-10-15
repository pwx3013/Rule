#!/usr/bin/env bash
# trojan-go 原生一键部署（Alpine Linux，OpenRC，不用 Docker）
# 用法（root）：bash deploy-trojan-alpine.sh
#   可选环境变量：TROJAN_PORT（默认 443）
set -euo pipefail

PORT="${TROJAN_PORT:-443}"
DIR="/opt/trojan-go"
VER="v0.10.6"

log() { echo "[trojan] $*"; }
die() { echo "[trojan] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 运行"

if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
  die "TCP ${PORT} 已被占用；换端口：TROJAN_PORT=xxxx bash $0"
fi

apk add --no-cache curl unzip openssl iproute2 >/dev/null

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)        TGO="amd64" ;;
  aarch64|arm64) TGO="armv8" ;;
  armv7l)        TGO="armv7" ;;
  *) die "不支持的架构: $ARCH" ;;
esac

PUBIP="$(curl -fsSL --max-time 10 https://api.ipify.org 2>/dev/null || curl -fsSL --max-time 10 https://ifconfig.me 2>/dev/null || true)"
[ -n "$PUBIP" ] || die "取不到公网 IP，请检查网络"

log "下载 trojan-go ${VER} (linux-${TGO})..."
cd /tmp
curl -fsSL -o trojan-go.zip "https://github.com/p4gefau1t/trojan-go/releases/download/${VER}/trojan-go-linux-${TGO}.zip"
mkdir -p "$DIR"
unzip -o -q trojan-go.zip -d "$DIR"
chmod +x "$DIR/trojan-go"

PASSWORD="$(openssl rand -hex 16)"
openssl ecparam -genkey -name prime256v1 -out "$DIR/key.pem" 2>/dev/null
openssl req -new -x509 -days 3650 -key "$DIR/key.pem" -out "$DIR/cert.pem" -subj "/CN=${PUBIP}" 2>/dev/null
FINGERPRINT="$(openssl x509 -in "$DIR/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')"

cat > "$DIR/config.json" <<EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": ${PORT},
  "remote_addr": "127.0.0.1",
  "remote_port": 80,
  "password": ["${PASSWORD}"],
  "ssl": {
    "cert": "${DIR}/cert.pem",
    "key": "${DIR}/key.pem",
    "sni": "${PUBIP}"
  },
  "disable_http_check": true,
  "verify_hostname": false
}
EOF
chmod 600 "$DIR/config.json"

# OpenRC 服务
cat > /etc/init.d/trojan-go <<EOF
#!/sbin/openrc-run
name="trojan-go"
command="${DIR}/trojan-go"
command_args="-config ${DIR}/config.json"
command_background=true
pidfile="/run/trojan-go.pid"
depend() {
  need net
}
EOF
chmod +x /etc/init.d/trojan-go
rc-update add trojan-go default >/dev/null
rc-service trojan-go start
sleep 2
rc-service trojan-go status | grep -q started || die "trojan-go 启动失败，请看日志"

echo
echo "================ 部署成功 ================"
echo "服务器 IP : ${PUBIP}"
echo "端口      : ${PORT} (TCP)"
echo "密码      : ${PASSWORD}"
echo "指纹      : ${FINGERPRINT}"
echo "=========================================="
echo "记得在云控制台放行 TCP ${PORT} 入站"
