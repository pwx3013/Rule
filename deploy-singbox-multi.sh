#!/usr/bin/env bash
# sing-box 多协议节点 Docker 一键部署
# 一次起 5 个协议：TUIC v5 / Hysteria2 / Trojan / VLESS / Shadowsocks
#
# 用法（root）：
#   bash deploy-singbox-multi.sh
# 或一键：
#   curl -fsSL <脚本URL> | sudo bash
#
# 可选环境变量（端口均可改，避开已有服务）：
#   HY2_PORT          Hysteria2 监听 UDP 端口（默认 14443）
#   TUIC_PORT         TUIC v5 监听 UDP 端口（默认 24443）
#   TROJAN_PORT       Trojan 监听 TCP 端口（默认 34443）
#   VLESS_PORT        VLESS 监听 TCP 端口（默认 44443）
#   SS_PORT           Shadowsocks 监听 TCP+UDP 端口（默认 54443）
#   SNI               TLS SNI（默认 www.bing.com）
#   SING_BOX_VERSION  镜像版本（默认 v1.14.2，支持 arm64）
#
# 行为：
#  - 优先复用本脚本上次的输出（/opt/singbox-multi/conf/meta.env），
#    重复运行不会更换 UUID / 密码 / 证书
#  - 全新部署生成 UUID + 各协议密码 + 自签证书（ECDSA P-256，10 年有效期），
#    结束时打印各协议的客户端配置
#
# 客户端支持情况（2026-10 实测文档）：
#   Surge  支持 TUIC v5 / Hysteria2 / Trojan / Shadowsocks，不支持 VLESS
#   Egern  五个全支持
set -euo pipefail

SNI="${SNI:-www.bing.com}"
VERSION="${SING_BOX_VERSION:-v1.14.2}"
DIR="/opt/singbox-multi"
CONF="$DIR/conf"
META="$CONF/meta.env"
IMAGE="ghcr.io/sagernet/sing-box:${VERSION}"

log() { echo "[singbox-multi] $*"; }
die() { echo "[singbox-multi] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 运行"
command -v docker >/dev/null 2>&1 || die "未找到 docker，请先安装 docker"
docker compose version >/dev/null 2>&1 || die "未找到 docker compose 插件"
command -v openssl >/dev/null 2>&1 || die "未找到 openssl"

# ---- 清理残留的旧容器（支持重复运行/修复）----
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx singbox-multi; then
  log "清理已存在的 singbox-multi 容器…"
  docker rm -f singbox-multi >/dev/null 2>&1 || true
fi

# ---- 凭据：优先复用，避免重复运行更换 ----
if [[ -f "$META" && -f "$CONF/cert.pem" && -f "$CONF/key.pem" ]]; then
  # shellcheck disable=SC1090
  source "$META"
  : "${UUID:?meta.env 损坏：缺少 UUID}" \
    "${PASSWORD:?meta.env 损坏：缺少 PASSWORD}" \
    "${SS_PASSWORD:?meta.env 损坏：缺少 SS_PASSWORD}"
  [ -n "${SNI:-}" ] || SNI="www.bing.com"
  log "复用已有部署的 UUID / 密码 / 证书…"
else
  log "生成新的 UUID、密码与自签证书…"
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    UUID="$(cat /proc/sys/kernel/random/uuid)"
  else
    UUID="$(openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')"
  fi
  PASSWORD="$(openssl rand -hex 16)"
  SS_PASSWORD="$(openssl rand -base64 16)"   # 2022-blake3-aes-128-gcm 需 16 字节 base64 密钥
  mkdir -p "$CONF"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$CONF/key.pem" -out "$CONF/cert.pem" -days 3650 -nodes \
    -subj "/CN=${SNI}" -addext "subjectAltName=DNS:${SNI}" 2>/dev/null
  chmod 600 "$CONF/key.pem" "$CONF/cert.pem"
fi

# ---- 端口：环境变量优先，其次沿用上次，最后用默认 ----
HY2_PORT="${HY2_PORT:-${HY2_PORT_SAVED:-14443}}"
TUIC_PORT="${TUIC_PORT:-${TUIC_PORT_SAVED:-24443}}"
TROJAN_PORT="${TROJAN_PORT:-${TROJAN_PORT_SAVED:-34443}}"
VLESS_PORT="${VLESS_PORT:-${VLESS_PORT_SAVED:-44443}}"
SS_PORT="${SS_PORT:-${SS_PORT_SAVED:-54443}}"
for p in "$HY2_PORT" "$TUIC_PORT" "$TROJAN_PORT" "$VLESS_PORT" "$SS_PORT"; do
  [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] \
    || die "端口无效：$p"
done

# 回写 meta.env（凭据唯一来源）
mkdir -p "$CONF"
cat > "$META" <<EOF
UUID=${UUID}
PASSWORD=${PASSWORD}
SS_PASSWORD=${SS_PASSWORD}
SNI=${SNI}
HY2_PORT_SAVED=${HY2_PORT}
TUIC_PORT_SAVED=${TUIC_PORT}
TROJAN_PORT_SAVED=${TROJAN_PORT}
VLESS_PORT_SAVED=${VLESS_PORT}
SS_PORT_SAVED=${SS_PORT}
EOF
chmod 600 "$META"

# ---- 端口占用检查 ----
check_tcp() { ss -tlnp 2>/dev/null | grep -q ":$1 " && die "TCP $1 已被占用；换个端口再跑"; }
check_udp() { ss -ulnp 2>/dev/null | grep -q ":$1 " && die "UDP $1 已被占用；换个端口再跑"; }
check_udp "$HY2_PORT"
check_udp "$TUIC_PORT"
check_tcp "$TROJAN_PORT"
check_tcp "$VLESS_PORT"
check_tcp "$SS_PORT"; check_udp "$SS_PORT"

# ---- sing-box 配置 ----
cat > "$CONF/config.json" <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [{ "password": "${PASSWORD}" }],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/key.pem"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": ${TUIC_PORT},
      "users": [{ "uuid": "${UUID}", "password": "${PASSWORD}" }],
      "congestion_control": "bbr",
      "zero_rtt_handshake": false,
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/key.pem"
      }
    },
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
      }
    },
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${VLESS_PORT},
      "users": [{ "uuid": "${UUID}" }],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/key.pem"
      }
    },
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": ${SS_PORT},
      "method": "2022-blake3-aes-128-gcm",
      "password": "${SS_PASSWORD}"
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": { "final": "direct" }
}
EOF
chmod 600 "$CONF/config.json"

# ---- docker-compose.yml ----
cat > "$DIR/docker-compose.yml" <<EOF
services:
  sing-box:
    image: ${IMAGE}
    container_name: singbox-multi
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./conf:/etc/sing-box
    command: ["run", "-c", "/etc/sing-box/config.json"]
EOF

# ---- 拉镜像并预检配置 ----
log "拉取镜像 ${IMAGE}…"
docker pull -q "$IMAGE" || die "镜像拉取失败"
log "预检 sing-box 配置…"
docker run --rm -v "$CONF:/etc/sing-box" "$IMAGE" check -c /etc/sing-box/config.json \
  || die "配置校验未通过"

# ---- 启动 ----
cd "$DIR"
docker compose up -d
sleep 3

# ---- 本机防火墙放行 ----
if command -v iptables >/dev/null 2>&1; then
  for p in "$TROJAN_PORT" "$VLESS_PORT"; do
    iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
  done
  for p in "$HY2_PORT" "$TUIC_PORT"; do
    iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
  done
  for proto in tcp udp; do
    iptables -C INPUT -p $proto --dport "$SS_PORT" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p $proto --dport "$SS_PORT" -j ACCEPT 2>/dev/null || true
  done
fi

docker ps --filter name=singbox-multi --format '{{.Status}}' | grep -qi up \
  || { docker logs singbox-multi --tail 30; die "容器未正常运行，见上方日志"; }

HOST="$(curl -fsSL --max-time 8 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"

cat <<DONE

======================================================================
 sing-box 多协议节点 (Docker) 部署完成
  监听：HY2 UDP ${HY2_PORT} / TUIC UDP ${TUIC_PORT} / Trojan TCP ${TROJAN_PORT}
        VLESS TCP ${VLESS_PORT} / SS TCP+UDP ${SS_PORT}
  镜像：${IMAGE}
  配置：${CONF}/config.json
  凭据：${META}
  运维：cd ${DIR} && docker compose {logs,restart,down}
======================================================================

----- Surge 配置行（[Proxy]，直接粘贴）-----
MB-TUIC   = tuic-v5, ${HOST}, ${TUIC_PORT}, uuid=${UUID}, password=${PASSWORD}, sni=${SNI}, alpn=h3, skip-cert-verify=true
MB-TROJAN = trojan, ${HOST}, ${TROJAN_PORT}, password=${PASSWORD}, sni=${SNI}, skip-cert-verify=true
MB-SS     = ss, ${HOST}, ${SS_PORT}, encrypt-method=2022-blake3-aes-128-gcm, password=${SS_PASSWORD}, udp-relay=true
# Hysteria2：Surge 仅基础支持，建议用下面的 hy2:// 链接导入或在 Egern 里配
# VLESS：Surge 不支持，用 Egern

----- 通用链接（Egern / Shadowrocket 等扫码或粘贴导入）-----
tuic://${UUID}:${PASSWORD}@${HOST}:${TUIC_PORT}?sni=${SNI}&alpn=h3&congestion_control=bbr#MB-TUIC
hysteria2://${PASSWORD}@${HOST}:${HY2_PORT}?sni=${SNI}&insecure=1#MB-HY2
trojan://${PASSWORD}@${HOST}:${TROJAN_PORT}?sni=${SNI}&allowInsecure=1#MB-TROJAN
vless://${UUID}@${HOST}:${VLESS_PORT}?security=tls&sni=${SNI}&allowInsecure=1#MB-VLESS
ss://$(echo -n "2022-blake3-aes-128-gcm:${SS_PASSWORD}" | base64 | tr -d '\n')@${HOST}:${SS_PORT}#MB-SS

----- 原始参数 -----
  服务器：${HOST}
  UUID：${UUID}（TUIC / VLESS 用）
  密码：${PASSWORD}（HY2 / Trojan / TUIC 用）
  SS 密钥：${SS_PASSWORD}（base64，Shadowsocks 2022 用）
  SNI：${SNI}
  证书：自签，客户端需开"跳过证书验证"
======================================================================
DONE
echo "云控制台必做：安全组放行 入站 TCP ${TROJAN_PORT},${VLESS_PORT},${SS_PORT} 与 UDP ${HY2_PORT},${TUIC_PORT},${SS_PORT}"
