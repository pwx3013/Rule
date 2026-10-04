#!/usr/bin/env bash
# sing-box 多协议节点 Docker 一键部署
# 一次起 11 个协议：
#   Hysteria2 / TUIC v5 / Trojan / VLESS / Shadowsocks2022 /
#   AnyTLS / VMess / NaiveProxy / WireGuard / HTTP+Socks5 混合 / TrustTunnel
#
# 前 10 个跑官方 sing-box 镜像；TrustTunnel 官方没有，只有第三方 fork
# （shtorm-7/sing-box-extended）才有。没有可用的预编译二进制，脚本在 VPS 上
# 从 fork 源码编译（pin 到 commit 5956780，已验证），单独跑一个服务。
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
#   ANYTLS_PORT       AnyTLS 监听 TCP 端口（默认 15443）
#   VMESS_PORT        VMess 监听 TCP 端口（默认 25443）
#   NAIVE_PORT        NaiveProxy 监听 TCP 端口（默认 35443）
#   WG_PORT           WireGuard 监听 UDP 端口（默认 45443）
#   MIXED_PORT        HTTP/Socks5 混合监听 TCP 端口（默认 46443）
#   TT_PORT           TrustTunnel 监听 TCP+UDP 端口（默认 47443）
#   SNI               TLS SNI（默认 www.bing.com）
#   SING_BOX_VERSION  镜像版本（默认 v1.14.2，支持 arm64；AnyTLS 需 >= 1.12）
#
# 行为：
#  - 优先复用本脚本上次的输出（/opt/singbox-multi/conf/meta.env），
#    重复运行不会更换 UUID / 密码 / 密钥 / 证书
#  - 全新部署生成 UUID + 各协议密码 + WireGuard 密钥对 + 自签证书
#    （ECDSA P-256，10 年有效期），结束时打印各协议的客户端配置
#
# 客户端支持情况（2026-10）：
#   Surge  支持 TUIC v5 / Hysteria2(基础) / Trojan / SS / VMess / AnyTLS / Socks5+HTTP，
#           不支持 VLESS / NaiveProxy / WireGuard（通用）/ TrustTunnel
#   Egern  除 NaiveProxy / TrustTunnel 外全支持
#   TrustTunnel 客户端：AdGuard 官方 TrustTunnel App（iOS/Android，可连自建服务器；
#           注意手机 App 不认自签证书，要用 iOS App 需换成 Let's Encrypt 证书）
set -euo pipefail

SNI="${SNI:-www.bing.com}"
VERSION="${SING_BOX_VERSION:-v1.14.2}"
DIR="/opt/singbox-multi"
CONF="$DIR/conf"
META="$CONF/meta.env"
IMAGE="ghcr.io/sagernet/sing-box:${VERSION}"
MIXED_USER="user"

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

# ---- 拉镜像（WireGuard 密钥对用它生成）----
log "拉取镜像 ${IMAGE}…"
docker pull -q "$IMAGE" || die "镜像拉取失败"

gen_wg_keypair() { # 输出一行："私钥 公钥"
  docker run --rm "$IMAGE" generate wg-keypair 2>/dev/null \
    | awk '/PrivateKey:/{p=$2} /PublicKey:/{q=$2} END{if (p && q) print p, q}'
}

# ---- 凭据：优先复用，避免重复运行更换 ----
if [[ -f "$META" && -f "$CONF/cert.pem" && -f "$CONF/key.pem" ]]; then
  # shellcheck disable=SC1090
  source "$META"
  : "${UUID:?meta.env 损坏：缺少 UUID}" \
    "${PASSWORD:?meta.env 损坏：缺少 PASSWORD}" \
    "${SS_PASSWORD:?meta.env 损坏：缺少 SS_PASSWORD}" \
    "${WG_SERVER_PRIV:?meta.env 损坏：缺少 WG_SERVER_PRIV}" \
    "${WG_CLIENT_PUB:?meta.env 损坏：缺少 WG_CLIENT_PUB}" \
    "${WG_CLIENT_PRIV:?meta.env 损坏：缺少 WG_CLIENT_PRIV}"
  [ -n "${SNI:-}" ] || SNI="www.bing.com"
  log "复用已有部署的 UUID / 密码 / 密钥 / 证书…"
else
  log "生成新的 UUID、密码、WireGuard 密钥对与自签证书…"
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    UUID="$(cat /proc/sys/kernel/random/uuid)"
  else
    UUID="$(openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')"
  fi
  PASSWORD="$(openssl rand -hex 16)"
  SS_PASSWORD="$(openssl rand -base64 16)"   # 2022-blake3-aes-128-gcm 需 16 字节 base64 密钥
  read -r WG_SERVER_PRIV WG_SERVER_PUB < <(gen_wg_keypair)
  [ -n "${WG_SERVER_PRIV:-}" ] && [ -n "${WG_SERVER_PUB:-}" ] || die "WireGuard 服务端密钥生成失败"
  read -r WG_CLIENT_PRIV WG_CLIENT_PUB < <(gen_wg_keypair)
  [ -n "${WG_CLIENT_PRIV:-}" ] && [ -n "${WG_CLIENT_PUB:-}" ] || die "WireGuard 客户端密钥生成失败"
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
ANYTLS_PORT="${ANYTLS_PORT:-${ANYTLS_PORT_SAVED:-15443}}"
VMESS_PORT="${VMESS_PORT:-${VMESS_PORT_SAVED:-25443}}"
NAIVE_PORT="${NAIVE_PORT:-${NAIVE_PORT_SAVED:-35443}}"
WG_PORT="${WG_PORT:-${WG_PORT_SAVED:-45443}}"
MIXED_PORT="${MIXED_PORT:-${MIXED_PORT_SAVED:-46443}}"
TT_PORT="${TT_PORT:-${TT_PORT_SAVED:-47443}}"
for p in "$HY2_PORT" "$TUIC_PORT" "$TROJAN_PORT" "$VLESS_PORT" "$SS_PORT" \
         "$ANYTLS_PORT" "$VMESS_PORT" "$NAIVE_PORT" "$WG_PORT" "$MIXED_PORT" "$TT_PORT"; do
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
WG_SERVER_PRIV=${WG_SERVER_PRIV}
WG_SERVER_PUB=${WG_SERVER_PUB}
WG_CLIENT_PRIV=${WG_CLIENT_PRIV}
WG_CLIENT_PUB=${WG_CLIENT_PUB}
HY2_PORT_SAVED=${HY2_PORT}
TUIC_PORT_SAVED=${TUIC_PORT}
TROJAN_PORT_SAVED=${TROJAN_PORT}
VLESS_PORT_SAVED=${VLESS_PORT}
SS_PORT_SAVED=${SS_PORT}
ANYTLS_PORT_SAVED=${ANYTLS_PORT}
VMESS_PORT_SAVED=${VMESS_PORT}
NAIVE_PORT_SAVED=${NAIVE_PORT}
WG_PORT_SAVED=${WG_PORT}
MIXED_PORT_SAVED=${MIXED_PORT}
TT_PORT_SAVED=${TT_PORT}
EOF
chmod 600 "$META"

# ---- 端口占用检查 ----
check_tcp() { ss -tlnp 2>/dev/null | grep -q ":$1 " && die "TCP $1 已被占用；换个端口再跑"; }
check_udp() { ss -ulnp 2>/dev/null | grep -q ":$1 " && die "UDP $1 已被占用；换个端口再跑"; }
check_udp "$HY2_PORT"
check_udp "$TUIC_PORT"
check_udp "$WG_PORT"
check_tcp "$TROJAN_PORT"
check_tcp "$VLESS_PORT"
check_tcp "$ANYTLS_PORT"
check_tcp "$VMESS_PORT"
check_tcp "$NAIVE_PORT"
check_tcp "$MIXED_PORT"
check_tcp "$SS_PORT"; check_udp "$SS_PORT"
check_tcp "$TT_PORT"; check_udp "$TT_PORT"

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
    },
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": ${ANYTLS_PORT},
      "users": [{ "name": "user", "password": "${PASSWORD}" }],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/key.pem"
      }
    },
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "::",
      "listen_port": ${VMESS_PORT},
      "users": [{ "uuid": "${UUID}", "alterId": 0 }],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/key.pem"
      }
    },
    {
      "type": "naive",
      "tag": "naive-in",
      "listen": "::",
      "listen_port": ${NAIVE_PORT},
      "users": [{ "username": "${MIXED_USER}", "password": "${PASSWORD}" }],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/key.pem"
      }
    },
    {
      "type": "wireguard",
      "tag": "wg-in",
      "listen": "::",
      "listen_port": ${WG_PORT},
      "private_key": "${WG_SERVER_PRIV}",
      "peers": [
        {
          "public_key": "${WG_CLIENT_PUB}",
          "allowed_ips": ["0.0.0.0/0", "::/0"]
        }
      ]
    },
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "::",
      "listen_port": ${MIXED_PORT},
      "users": [{ "username": "${MIXED_USER}", "password": "${PASSWORD}" }]
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": { "final": "direct" }
}
EOF
chmod 600 "$CONF/config.json"

# ================= TrustTunnel（第 11 个协议，fork 源码编译独立服务）=================
# 官方 sing-box 没有 TrustTunnel，只有第三方 fork（shtorm-7/sing-box-extended）有。
# 没有可用的预编译二进制，脚本在 VPS 上从源码编译（pin 到验证过的 commit）。
TT_BIN_DIR="$DIR/bin"
TT_BIN="$TT_BIN_DIR/sing-box-extended"
TT_IMAGE="singbox-extended:local"
TT_SRC="$DIR/src/sing-box-extended"
TT_COMMIT="5956780"   # 已验证含 TrustTunnel inbound 的 commit
TT_TAGS="with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api,with_tailscale,with_manager,with_masque,with_mtproxy,with_ccm,with_ocm,with_trusttunnel,with_call,with_sudoku,with_cloudflared,with_usbip,with_openvpn,with_openconnect,badlinkname,tfogo_checklinkname0"
GO_DIR="/usr/local/go"

# 清理残留的旧容器
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx singbox-trusttunnel; then
  log "清理已存在的 singbox-trusttunnel 容器…"
  docker rm -f singbox-trusttunnel >/dev/null 2>&1 || true
fi

if [[ ! -x "$TT_BIN" ]]; then
  # ---- Go 工具链（fork 要求 go >= 1.26）----
  if ! command -v go >/dev/null 2>&1 || ! go version 2>/dev/null | grep -Eq "go1\.(2[6-9]|[3-9][0-9])"; then
    log "安装 Go 1.26 工具链…"
    case "$(uname -m)" in
      x86_64) GO_ARCH="amd64" ;;
      aarch64) GO_ARCH="arm64" ;;
      *) die "不支持的架构：$(uname -m)" ;;
    esac
    curl -fsSL --max-time 180 -o /tmp/go.tgz "https://go.dev/dl/go1.26.4.linux-${GO_ARCH}.tar.gz" \
      || die "Go 下载失败（检查 go.dev 连通性）"
    rm -rf "$GO_DIR" && tar -C /usr/local -xzf /tmp/go.tgz && rm -f /tmp/go.tgz
    export PATH="$GO_DIR/bin:$PATH"
    go version || die "Go 安装失败"
  fi
  command -v git >/dev/null 2>&1 || die "未找到 git，请先安装 git（apt install -y git）"

  # ---- 拉源码（pin 到验证过的 commit）----
  log "获取 sing-box-extended 源码…"
  rm -rf "$TT_SRC"; mkdir -p "$TT_SRC"
  git -C "$TT_SRC" init -q
  git -C "$TT_SRC" remote add origin https://github.com/shtorm-7/sing-box-extended.git
  git -C "$TT_SRC" fetch --depth 1 origin "$TT_COMMIT" || die "源码获取失败"
  git -C "$TT_SRC" checkout -q FETCH_HEAD

  # ---- 编译（约 10 分钟，一次性；二进制复用，重复运行跳过）----
  log "编译 TrustTunnel 二进制（约 10 分钟，第一次才需要）…"
  mkdir -p "$TT_BIN_DIR" "$DIR/gotmp" "$DIR/gocache"
  ( cd "$TT_SRC" && \
    CGO_ENABLED=0 GOTMPDIR="$DIR/gotmp" GOCACHE="$DIR/gocache" \
    PATH="$GO_DIR/bin:$PATH" \
    go build -trimpath -ldflags="-s -w" -tags "$TT_TAGS" -o "$TT_BIN" ./cmd/sing-box ) \
    || die "TrustTunnel 编译失败"
  chmod +x "$TT_BIN"
  log "编译完成"
else
  log "复用已编译的 TrustTunnel 二进制…"
fi

# TrustTunnel 独立配置（只跑这一个 inbound）
cat > "$CONF/tt-config.json" <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "trusttunnel",
      "tag": "tt-in",
      "listen": "::",
      "listen_port": ${TT_PORT},
      "users": [{ "name": "${MIXED_USER}", "password": "${PASSWORD}" }],
      "network": ["tcp", "udp"],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/key.pem"
      }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": { "final": "direct" }
}
EOF
chmod 600 "$CONF/tt-config.json"

# 用下载的二进制直接预检（静态二进制，无需 docker）
log "预检 TrustTunnel 配置…"
"$TT_BIN" check -c "$CONF/tt-config.json" || die "TrustTunnel 配置校验未通过"

# 给 fork 二进制打一个最小镜像（scratch + 二进制）
cat > "$DIR/Dockerfile.tt" <<'DOCKEREOF'
FROM scratch
COPY bin/sing-box-extended /usr/local/bin/sing-box
ENTRYPOINT ["/usr/local/bin/sing-box"]
DOCKEREOF
log "构建 TrustTunnel 镜像…"
docker build -q -f "$DIR/Dockerfile.tt" -t "$TT_IMAGE" "$DIR" || die "TrustTunnel 镜像构建失败"

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
  sing-box-tt:
    image: ${TT_IMAGE}
    container_name: singbox-trusttunnel
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./conf:/etc/sing-box
    command: ["run", "-c", "/etc/sing-box/tt-config.json"]
EOF

# ---- 预检配置 ----
log "预检 sing-box 配置…"
docker run --rm -v "$CONF:/etc/sing-box" "$IMAGE" check -c /etc/sing-box/config.json \
  || die "配置校验未通过"

# ---- 启动 ----
cd "$DIR"
docker compose up -d
sleep 3

# ---- 本机防火墙放行 ----
if command -v iptables >/dev/null 2>&1; then
  for p in "$TROJAN_PORT" "$VLESS_PORT" "$ANYTLS_PORT" "$VMESS_PORT" "$NAIVE_PORT" "$MIXED_PORT"; do
    iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
  done
  for p in "$HY2_PORT" "$TUIC_PORT" "$WG_PORT"; do
    iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
  done
  for proto in tcp udp; do
    iptables -C INPUT -p $proto --dport "$SS_PORT" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p $proto --dport "$SS_PORT" -j ACCEPT 2>/dev/null || true
    iptables -C INPUT -p $proto --dport "$TT_PORT" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p $proto --dport "$TT_PORT" -j ACCEPT 2>/dev/null || true
  done
fi

docker ps --filter name=singbox-multi --format '{{.Status}}' | grep -qi up \
  || { docker logs singbox-multi --tail 30; die "容器未正常运行，见上方日志"; }
docker ps --filter name=singbox-trusttunnel --format '{{.Status}}' | grep -qi up \
  || { docker logs singbox-trusttunnel --tail 30; die "TrustTunnel 容器未正常运行，见上方日志"; }

HOST="$(curl -fsSL --max-time 8 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"

cat <<DONE

======================================================================
 sing-box 十一协议节点 (Docker) 部署完成
  监听：HY2 UDP ${HY2_PORT} / TUIC UDP ${TUIC_PORT} / Trojan TCP ${TROJAN_PORT}
        VLESS TCP ${VLESS_PORT} / SS TCP+UDP ${SS_PORT}
        AnyTLS TCP ${ANYTLS_PORT} / VMess TCP ${VMESS_PORT} / Naive TCP ${NAIVE_PORT}
        WireGuard UDP ${WG_PORT} / 混合 TCP ${MIXED_PORT}
        TrustTunnel TCP+UDP ${TT_PORT}（fork 二进制独立服务）
  镜像：${IMAGE} + ${TT_IMAGE}（fork 编译版）
  配置：${CONF}/config.json
  凭据：${META}
  运维：cd ${DIR} && docker compose {logs,restart,down}
======================================================================

----- Surge 配置行（[Proxy]，直接粘贴）-----
MB-TUIC   = tuic-v5, ${HOST}, ${TUIC_PORT}, uuid=${UUID}, password=${PASSWORD}, sni=${SNI}, alpn=h3, skip-cert-verify=true
MB-TROJAN = trojan, ${HOST}, ${TROJAN_PORT}, password=${PASSWORD}, sni=${SNI}, skip-cert-verify=true
MB-SS     = ss, ${HOST}, ${SS_PORT}, encrypt-method=2022-blake3-aes-128-gcm, password=${SS_PASSWORD}, udp-relay=true
MB-VMESS  = vmess, ${HOST}, ${VMESS_PORT}, username=${UUID}, tls=true, skip-cert-verify=true
MB-SOCKS  = socks5, ${HOST}, ${MIXED_PORT}, username=${MIXED_USER}, password=${PASSWORD}
# Hysteria2：Surge 仅基础支持，建议用下面的 hy2:// 链接导入或在 Egern 里配
# AnyTLS：Surge/Egern 均支持，用下面的 anytls:// 链接导入
# VLESS：Surge 不支持，用 Egern（下面的 vless:// 链接）
# Naive：iOS 暂无客户端，用桌面端 sing-box
# WireGuard：用官方 WireGuard App 或 Egern，按下方参数填
# TrustTunnel：用 AdGuard 官方 TrustTunnel App（iOS/Android）连自建服务器，
#   按下方参数填；注意手机 App 不认自签证书，要用它需换成 Let's Encrypt 证书

----- 通用链接（Egern / Shadowrocket 等粘贴导入）-----
tuic://${UUID}:${PASSWORD}@${HOST}:${TUIC_PORT}?sni=${SNI}&alpn=h3&congestion_control=bbr#MB-TUIC
hysteria2://${PASSWORD}@${HOST}:${HY2_PORT}?sni=${SNI}&insecure=1#MB-HY2
trojan://${PASSWORD}@${HOST}:${TROJAN_PORT}?sni=${SNI}&allowInsecure=1#MB-TROJAN
vless://${UUID}@${HOST}:${VLESS_PORT}?security=tls&sni=${SNI}&allowInsecure=1#MB-VLESS
anytls://${PASSWORD}@${HOST}:${ANYTLS_PORT}?sni=${SNI}&insecure=1#MB-AnyTLS
vmess://$(echo -n "{\"v\":\"2\",\"ps\":\"MB-VMess\",\"add\":\"${HOST}\",\"port\":\"${VMESS_PORT}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"net\":\"tcp\",\"type\":\"none\",\"tls\":\"tls\",\"sni\":\"${SNI}\",\"allowInsecure\":1}" | base64 | tr -d '\n')
ss://$(echo -n "2022-blake3-aes-128-gcm:${SS_PASSWORD}" | base64 | tr -d '\n')@${HOST}:${SS_PORT}#MB-SS

----- WireGuard 参数（Egern / 官方 App）-----
  服务器：${HOST}    端口：${WG_PORT}（UDP）
  客户端私钥：${WG_CLIENT_PRIV}
  服务端公钥：${WG_SERVER_PUB}
  允许 IP：0.0.0.0/0, ::/0

----- Naive / 混合 原始参数 -----
  Naive：${HOST}:${NAIVE_PORT}，用户名 ${MIXED_USER}，密码见下方，TLS SNI=${SNI}（跳过证书验证）
  混合：${HOST}:${MIXED_PORT}，HTTP/Socks5 通吃，用户名 ${MIXED_USER}

----- TrustTunnel 参数（AdGuard 官方 TrustTunnel App）-----
  服务器：${HOST}    端口：${TT_PORT}（TCP+UDP）
  用户名：${MIXED_USER}
  密码：${PASSWORD}
  TLS SNI：${SNI}（自签证书；手机 App 不认自签，需换 Let's Encrypt 证书才能用）

----- 原始参数 -----
  服务器：${HOST}
  UUID：${UUID}（TUIC / VLESS / VMess 用）
  密码：${PASSWORD}（HY2 / Trojan / TUIC / AnyTLS / Naive / 混合 / TrustTunnel 用）
  SS 密钥：${SS_PASSWORD}（base64，Shadowsocks 2022 用）
  SNI：${SNI}
  证书：自签，客户端需开"跳过证书验证"
======================================================================
DONE
echo "云控制台必做：安全组放行 入站 TCP ${TROJAN_PORT},${VLESS_PORT},${SS_PORT},${ANYTLS_PORT},${VMESS_PORT},${NAIVE_PORT},${MIXED_PORT},${TT_PORT} 与 UDP ${HY2_PORT},${TUIC_PORT},${SS_PORT},${WG_PORT},${TT_PORT}"
