#!/usr/bin/env bash
# sing-box VMess 一键部署（Alpine Linux，OpenRC）
# 用法（root）：bash deploy-vmess-alpine.sh
#   可选环境变量：VMESS_PORT（默认 443）
#
# 行为：
#  - 下载 sing-box 最新稳定版（自动识别架构）
#  - 生成随机 UUID
#  - VMess + TCP，不套 TLS（先测连通性；如需 TLS 再加）
#  - 写入 OpenRC 服务 sing-box，开机自启
set -euo pipefail

PORT="${VMESS_PORT:-443}"
DIR="/opt/sing-box-vmess"

log() { echo "[vmess] $*"; }
die() { echo "[vmess] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 运行"

if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
  die "TCP ${PORT} 已被占用；换端口：VMESS_PORT=xxxx bash $0"
fi

apk add --no-cache curl unzip gcompat >/dev/null

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)        SGO="amd64" ;;
  aarch64|arm64) SGO="arm64" ;;
  armv7l)        SGO="armv7" ;;
  *) die "不支持的架构: $ARCH" ;;
esac

# 取最新版本号
VER="$(curl -fsSL --max-time 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -o '"tag_name": "v[^"]*"' | head -1 | cut -d'"' -f4)"
[ -n "$VER" ] || die "取不到 sing-box 版本号"
log "下载 sing-box ${VER} (linux-${SGO})..."
cd /tmp
curl -fsSL -o sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/${VER}/sing-box-${VER#v}-linux-${SGO}.tar.gz"
mkdir -p "$DIR"
tar -xzf sing-box.tar.gz -C /tmp
cp "/tmp/sing-box-${VER#v}-linux-${SGO}/sing-box" "$DIR/sing-box"
chmod +x "$DIR/sing-box"

UUID="$("$DIR/sing-box" generate uuid)"

cat > "$DIR/config.json" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "0.0.0.0",
      "listen_port": ${PORT},
      "users": [
        { "uuid": "${UUID}", "alterId": 0 }
      ]
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF
chmod 600 "$DIR/config.json"

cat > /etc/init.d/sing-box-vmess <<EOF
#!/sbin/openrc-run
name="sing-box-vmess"
command="${DIR}/sing-box"
command_args="run -c ${DIR}/config.json"
command_background=true
pidfile="/run/sing-box-vmess.pid"
depend() {
  need net
}
EOF
chmod +x /etc/init.d/sing-box-vmess
rc-update add sing-box-vmess default >/dev/null
rc-service sing-box-vmess start
sleep 2

PUBIP="$(curl -fsSL --max-time 10 https://api.ipify.org 2>/dev/null || echo "未知")"

echo
echo "================ 部署成功 ================"
echo "服务器 IP : ${PUBIP}"
echo "端口      : ${PORT} (TCP)"
echo "UUID      : ${UUID}"
echo "alterId   : 0"
echo "传输      : tcp（无 TLS，先测连通）"
echo "=========================================="
echo "vmess 链接："
echo "vmess://$(echo -n "{\"v\":\"2\",\"ps\":\"alpine-vmess\",\"add\":\"${PUBIP}\",\"port\":\"${PORT}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"net\":\"tcp\",\"type\":\"none\",\"host\":\"\",\"path\":\"\",\"tls\":\"\"}" | base64 -w0)"
echo
echo "记得在云控制台放行 TCP ${PORT} 入站"
