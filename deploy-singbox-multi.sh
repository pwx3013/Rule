#!/usr/bin/env bash
# sing-box 多协议节点 Docker 一键部署
# 一次起最多 10 个协议（DISABLE 可关闭不需要的）：
#   Hysteria2 / TUIC v5 / Trojan / VLESS / Shadowsocks2022 /
#   AnyTLS / VMess / NaiveProxy / WireGuard / HTTP+Socks5 混合
#
# 全部跑官方 sing-box 镜像（ghcr.io/sagernet/sing-box）。
#
# 用法（root）：
#   bash deploy-singbox-multi.sh
# 或一键：
#   curl -fsSL <脚本URL> | sudo bash
#
# 交互式管理菜单（233boy 风格：查看节点/改端口/换密码/换UUID/换SS加密/开关协议/重启/卸载）：
#   bash deploy-singbox-multi.sh menu
#   curl -fsSL <脚本URL> | sudo bash -s menu
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
#   SNI               TLS SNI（默认 www.bing.com）
#   SING_BOX_VERSION  镜像版本（默认 v1.14.2，支持 arm64；AnyTLS 需 >= 1.12）
#   DISABLE           关闭指定协议，逗号分隔（默认全开）：
#                     hy2,tuic,trojan,vless,ss,anytls,vmess,naive,wg,mixed
#                     例：DISABLE=naive,wg；DISABLE=none 表示清空（全部启用）
#   SS_METHOD         Shadowsocks 加密方式：
#                     2022-blake3-aes-128-gcm（默认）/ 2022-blake3-aes-256-gcm
#   RESET_PASSWORD=1  重新生成密码（HY2/Trojan/TUIC/AnyTLS/Naive/混合共用）
#   RESET_UUID=1      重新生成 UUID（TUIC/VLESS/VMess 共用）
#   RESET_SS_KEY=1    重新生成 SS 密钥（改 SS_METHOD 会自动重生成，无需加此项）
#
# 用法示例（改已部署的配置，直接重跑脚本）：
#   改端口：  HY2_PORT=8443 bash deploy-singbox-multi.sh
#   关协议：  DISABLE=naive bash deploy-singbox-multi.sh
#   换密码：  RESET_PASSWORD=1 bash deploy-singbox-multi.sh
#   换加密：  SS_METHOD=2022-blake3-aes-256-gcm bash deploy-singbox-multi.sh
# 一键（curl 管道时把变量放在 bash 前）：
#   curl -fsSL <脚本URL> | DISABLE=naive bash
#
# 行为：
#  - 优先复用本脚本上次的输出（/opt/singbox-multi/conf/meta.env），
#    重复运行默认不更换 UUID / 密码 / 密钥 / 证书 / 端口 / 协议开关
#  - 环境变量 > 上次保存的值 > 默认值；RESET_*=1 则强制重新生成对应凭据
#
# 客户端支持情况（2026-10）：
#   Surge  支持 TUIC v5 / Hysteria2(基础) / Trojan / SS / VMess / AnyTLS / Socks5+HTTP，
#           不支持 VLESS / NaiveProxy / WireGuard（通用）
#   Egern  除 NaiveProxy 外全支持
set -euo pipefail

SNI="${SNI:-www.bing.com}"
VERSION="${SING_BOX_VERSION:-v1.14.2}"
DIR="/opt/singbox-multi"
CONF="$DIR/conf"
META="$CONF/meta.env"
IMAGE="ghcr.io/sagernet/sing-box:${VERSION}"
MIXED_USER="user"

# ---- 协议开关 ----
# DISABLE: 逗号分隔要关闭的协议 key（默认全开）；环境变量 > 上次保存 > 默认
# 合法 key: hy2, tuic, trojan, vless, ss, anytls, vmess, naive, wg, mixed
# 例：DISABLE=naive,wg
is_enabled() { # $1 = key；返回 0 表示启用
  local key="$1" d=",${DISABLE:-},"
  case "$d" in *,"$key",*) return 1;; esac
  return 0
}

log() { echo "[singbox-multi] $*"; }
die() { echo "[singbox-multi] ERROR: $*" >&2; exit 1; }

# ================= 交互式管理菜单（233boy 风格）==================
# 用法：
#   bash deploy-singbox-multi.sh menu
#   curl -fsSL <脚本URL> | bash -s menu
SCRIPT_URL="https://raw.githubusercontent.com/pwx3013/Rule/main/deploy-singbox-multi.sh"
MENU_SELF="/tmp/singbox-multi-menu.sh"

menu_read() { # $1=提示语 $2=变量名；从 /dev/tty 读取（兼容 curl|bash）
  local prompt="$1" name="$2" val=""
  printf "%s" "$prompt" > /dev/tty
  IFS= read -r val < /dev/tty || true
  printf -v "$name" "%s" "$val"
}

menu_meta() {
  [ -f "$META" ] || die "未找到已部署配置（$META），请先执行部署"
  # shellcheck disable=SC1090
  source "$META"
}

menu_node_row() { # $1=显示名 $2=key $3=端口 $4=协议
  local name="$1" key="$2" port="$3" proto="$4" status="启用"
  case ",${DISABLE_SAVED:-}," in *,"$key",*) status="已关闭";; esac
  printf "  %-12s %s/%-5s  %s\n" "$name" "$proto" "$port" "$status"
}

menu_show_nodes() {
  menu_meta
  echo ""
  echo "---------- 已部署节点 ----------"
  menu_node_row "Hysteria2"   "hy2"    "${HY2_PORT_SAVED:-?}"    "UDP"
  menu_node_row "TUIC v5"     "tuic"   "${TUIC_PORT_SAVED:-?}"   "UDP"
  menu_node_row "Trojan"      "trojan" "${TROJAN_PORT_SAVED:-?}" "TCP"
  menu_node_row "VLESS"       "vless"  "${VLESS_PORT_SAVED:-?}"  "TCP"
  menu_node_row "Shadowsocks" "ss"     "${SS_PORT_SAVED:-?}"     "TCP+UDP"
  menu_node_row "AnyTLS"      "anytls" "${ANYTLS_PORT_SAVED:-?}" "TCP"
  menu_node_row "VMess"       "vmess"  "${VMESS_PORT_SAVED:-?}"  "TCP"
  menu_node_row "NaiveProxy"  "naive"  "${NAIVE_PORT_SAVED:-?}"  "TCP"
  menu_node_row "WireGuard"   "wg"     "${WG_PORT_SAVED:-?}"     "UDP"
  menu_node_row "混合"        "mixed"  "${MIXED_PORT_SAVED:-?}"  "TCP"
  echo ""
  echo "  UUID: ${UUID:-}"
  echo "  密码: ${PASSWORD:-}"
  echo "  SS: ${SS_METHOD_SAVED:-2022-blake3-aes-128-gcm} / ${SS_PASSWORD:-}"
  echo "  SNI: ${SNI:-www.bing.com}"
  echo ""
}

menu_rerun() { # VAR=val ...：带环境变量重新执行部署脚本，完成后返回菜单
  log "应用更改，重新部署..."
  env "$@" bash "$MENU_SELF" || log "重新部署未成功完成"
}

menu_change_port() {
  menu_meta
  echo ""
  echo "  1.Hysteria2(UDP)  2.TUIC(UDP)  3.Trojan(TCP)  4.VLESS(TCP)  5.SS(TCP+UDP)"
  echo "  6.AnyTLS(TCP)  7.VMess(TCP)  8.Naive(TCP)  9.WireGuard(UDP)  10.混合(TCP)"
  menu_read "选择协议编号 [1-10]: " n
  menu_read "输入新端口: " p
  local var=""
  case "$n" in
    1) var=HY2_PORT;; 2) var=TUIC_PORT;; 3) var=TROJAN_PORT;; 4) var=VLESS_PORT;;
    5) var=SS_PORT;; 6) var=ANYTLS_PORT;; 7) var=VMESS_PORT;; 8) var=NAIVE_PORT;;
    9) var=WG_PORT;; 10) var=MIXED_PORT;; *) echo "无效编号"; return 0;;
  esac
  [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || { echo "端口无效"; return 0; }
  menu_rerun "$var=$p"
}

menu_change_ss_method() {
  menu_meta
  echo ""
  echo "当前: ${SS_METHOD_SAVED:-2022-blake3-aes-128-gcm}"
  echo "  1. 2022-blake3-aes-128-gcm"
  echo "  2. 2022-blake3-aes-256-gcm"
  menu_read "请选择 [1-2]: " c
  case "$c" in
    1) menu_rerun "SS_METHOD=2022-blake3-aes-128-gcm";;
    2) menu_rerun "SS_METHOD=2022-blake3-aes-256-gcm";;
    *) echo "无效选择";;
  esac
}

menu_toggle_protos() {
  menu_meta
  echo ""
  echo "当前关闭: ${DISABLE_SAVED:-(无)}"
  echo "可选 key: hy2,tuic,trojan,vless,ss,anytls,vmess,naive,wg,mixed"
  menu_read "输入要关闭的 key（逗号分隔，直接回车=全部启用）: " d
  [ -z "$d" ] && d="none"
  menu_rerun "DISABLE=$d"
}

menu_restart() {
  [ -d "$DIR" ] || { echo "未找到部署目录"; return 0; }
  (cd "$DIR" && docker compose restart) && echo "服务已重启" || echo "重启失败"
}

menu_uninstall() {
  menu_read "确认卸载 sing-box 多协议？输入 y 确认: " yn
  [ "$yn" = "y" ] || { echo "已取消"; return 0; }
  menu_read "将删除 $DIR（含全部配置），再次输入 y 确认: " yn2
  [ "$yn2" = "y" ] || { echo "已取消"; return 0; }
  (cd "$DIR" && docker compose down 2>/dev/null) || true
  docker rm -f singbox-multi 2>/dev/null || true
  rm -rf "$DIR"
  echo "已卸载"
  exit 0
}

run_menu() {
  [ -e /dev/tty ] || die "菜单模式需要交互式终端"
  command -v docker >/dev/null 2>&1 || die "未找到 docker，请先安装 docker"
  log "准备管理菜单..."
  curl -fsSL --max-time 30 "$SCRIPT_URL" -o "$MENU_SELF" || die "脚本下载失败，检查网络"
  while true; do
    echo ""
    echo "====== sing-box 多协议管理 ======"
    echo " 1. 查看节点信息"
    echo " 2. 修改协议端口"
    echo " 3. 更换密码"
    echo " 4. 更换 UUID"
    echo " 5. 更换 SS 加密方式"
    echo " 6. 开关协议"
    echo " 7. 重启服务"
    echo " 8. 卸载"
    echo " 0. 退出"
    echo "================================"
    menu_read "请选择 [0-8]: " c
    case "$c" in
      1) menu_show_nodes;;
      2) menu_change_port;;
      3) menu_read "确认更换共用密码？(y/N): " yn
         [ "$yn" = "y" ] && menu_rerun "RESET_PASSWORD=1" || true;;
      4) menu_read "确认更换 UUID？(y/N): " yn
         [ "$yn" = "y" ] && menu_rerun "RESET_UUID=1" || true;;
      5) menu_change_ss_method;;
      6) menu_toggle_protos;;
      7) menu_restart;;
      8) menu_uninstall;;
      0) exit 0;;
      *) echo "无效选择";;
    esac
  done
}

[ "$(id -u)" = "0" ] || die "请用 root 运行"

# menu 模式分发（放 root 检查之后、docker 检查之前）
if [ "${1:-}" = "menu" ]; then
  run_menu
  exit 0
fi
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

gen_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'
  fi
}

# ---- 凭据：优先复用，避免重复运行更换 ----
if [[ -f "$META" && -f "$CONF/cert.pem" && -f "$CONF/key.pem" ]]; then
  # shellcheck disable=SC1090
  source "$META"
  : "${UUID:?meta.env 损坏：缺少 UUID}" \
    "${PASSWORD:?meta.env 损坏：缺少 PASSWORD}" \
    "${SS_PASSWORD:?meta.env 损坏：缺少 SS_PASSWORD}"
  [ -n "${SNI:-}" ] || SNI="www.bing.com"
  log "复用已有部署的 UUID / 密码 / 密钥 / 证书…"
else
  log "生成新的 UUID、密码与自签证书…"
  UUID="$(gen_uuid)"
  PASSWORD="$(openssl rand -hex 16)"
  SS_PASSWORD="$(openssl rand -base64 16)"
  mkdir -p "$CONF"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$CONF/key.pem" -out "$CONF/cert.pem" -days 3650 -nodes \
    -subj "/CN=${SNI}" -addext "subjectAltName=DNS:${SNI}" 2>/dev/null
  chmod 600 "$CONF/key.pem" "$CONF/cert.pem"
fi

# 协议开关：环境变量 > 上次保存 > 默认全开（DISABLE=none 表示清空，即全部启用）
if [ "${DISABLE:-}" = "none" ]; then
  DISABLE=""
else
  DISABLE="${DISABLE:-${DISABLE_SAVED:-}}"
fi

# ---- 凭据修改项（RESET_*=1 强制重新生成）----
if [[ "${RESET_PASSWORD:-0}" = "1" ]]; then
  PASSWORD="$(openssl rand -hex 16)"
  log "密码已重新生成（HY2/Trojan/TUIC/AnyTLS/Naive/混合共用）"
fi
if [[ "${RESET_UUID:-0}" = "1" ]]; then
  UUID="$(gen_uuid)"
  log "UUID 已重新生成（TUIC/VLESS/VMess 共用）"
fi

# ---- SS 加密方式（改方式会自动按新长度重生成密钥）----
SS_METHOD="${SS_METHOD:-${SS_METHOD_SAVED:-2022-blake3-aes-128-gcm}}"
case "$SS_METHOD" in
  2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm) ;;
  *) die "SS_METHOD 无效：$SS_METHOD（可选 2022-blake3-aes-128-gcm / 2022-blake3-aes-256-gcm）" ;;
esac
if [[ "${RESET_SS_KEY:-0}" = "1" || "$SS_METHOD" != "${SS_METHOD_SAVED:-2022-blake3-aes-128-gcm}" ]]; then
  if [[ "$SS_METHOD" = "2022-blake3-aes-256-gcm" ]]; then
    SS_PASSWORD="$(openssl rand -base64 32)"
  else
    SS_PASSWORD="$(openssl rand -base64 16)"
  fi
  log "SS 密钥已重新生成（$SS_METHOD）"
fi

# ---- WireGuard 密钥对（启用且缺失时生成）----
if is_enabled wg; then
  if [[ -z "${WG_SERVER_PRIV:-}" || -z "${WG_SERVER_PUB:-}" || -z "${WG_CLIENT_PRIV:-}" || -z "${WG_CLIENT_PUB:-}" ]]; then
    log "生成 WireGuard 密钥对…"
    read -r WG_SERVER_PRIV WG_SERVER_PUB < <(gen_wg_keypair)
    [ -n "${WG_SERVER_PRIV:-}" ] && [ -n "${WG_SERVER_PUB:-}" ] || die "WireGuard 服务端密钥生成失败"
    read -r WG_CLIENT_PRIV WG_CLIENT_PUB < <(gen_wg_keypair)
    [ -n "${WG_CLIENT_PRIV:-}" ] && [ -n "${WG_CLIENT_PUB:-}" ] || die "WireGuard 客户端密钥生成失败"
  fi
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
for p in "$HY2_PORT" "$TUIC_PORT" "$TROJAN_PORT" "$VLESS_PORT" "$SS_PORT" \
         "$ANYTLS_PORT" "$VMESS_PORT" "$NAIVE_PORT" "$WG_PORT" "$MIXED_PORT"; do
  [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] \
    || die "端口无效：$p"
done

# 回写 meta.env（凭据唯一来源）
mkdir -p "$CONF"
cat > "$META" <<EOF
UUID=${UUID}
PASSWORD=${PASSWORD}
SS_PASSWORD=${SS_PASSWORD}
SS_METHOD=${SS_METHOD}
SNI=${SNI}
DISABLE=${DISABLE}
WG_SERVER_PRIV=${WG_SERVER_PRIV:-}
WG_SERVER_PUB=${WG_SERVER_PUB:-}
WG_CLIENT_PRIV=${WG_CLIENT_PRIV:-}
WG_CLIENT_PUB=${WG_CLIENT_PUB:-}
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
SS_METHOD_SAVED=${SS_METHOD}
DISABLE_SAVED=${DISABLE}
EOF
chmod 600 "$META"

# ---- 端口占用检查（注意：set -e 下函数必须显式 return 0，否则端口空闲时 grep 返回 1 会直接杀掉脚本）----
check_tcp() { ss -tlnp 2>/dev/null | grep -q ":$1 " && die "TCP $1 已被占用；换个端口再跑"; return 0; }
check_udp() { ss -ulnp 2>/dev/null | grep -q ":$1 " && die "UDP $1 已被占用；换个端口再跑"; return 0; }
if is_enabled hy2; then check_udp "$HY2_PORT"; fi
if is_enabled tuic; then check_udp "$TUIC_PORT"; fi
if is_enabled wg; then check_udp "$WG_PORT"; fi
if is_enabled trojan; then check_tcp "$TROJAN_PORT"; fi
if is_enabled vless; then check_tcp "$VLESS_PORT"; fi
if is_enabled anytls; then check_tcp "$ANYTLS_PORT"; fi
if is_enabled vmess; then check_tcp "$VMESS_PORT"; fi
if is_enabled naive; then check_tcp "$NAIVE_PORT"; fi
if is_enabled mixed; then check_tcp "$MIXED_PORT"; fi
if is_enabled ss; then check_tcp "$SS_PORT"; check_udp "$SS_PORT"; fi

# ---- sing-box 配置（按 DISABLE 组装 inbounds）----
INBOUNDS=""
add_inbound() { # $1: JSON 片段（调用处已展开变量）
  if [ -n "$INBOUNDS" ]; then INBOUNDS="$INBOUNDS,"; fi
  INBOUNDS="$INBOUNDS
$1"
}

# WireGuard 在 sing-box >= 1.11 是 endpoint 类型，不再是 inbound
ENDPOINTS=""
add_endpoint() { # $1: JSON 片段（调用处已展开变量）
  if [ -n "$ENDPOINTS" ]; then ENDPOINTS="$ENDPOINTS,"; fi
  ENDPOINTS="$ENDPOINTS
$1"
}

if is_enabled hy2; then
  add_inbound "$(cat <<EOF
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
    }
EOF
)"
fi

if is_enabled tuic; then
  add_inbound "$(cat <<EOF
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
    }
EOF
)"
fi

if is_enabled trojan; then
  add_inbound "$(cat <<EOF
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
    }
EOF
)"
fi

if is_enabled vless; then
  add_inbound "$(cat <<EOF
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
    }
EOF
)"
fi

if is_enabled ss; then
  add_inbound "$(cat <<EOF
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": ${SS_PORT},
      "method": "${SS_METHOD}",
      "password": "${SS_PASSWORD}"
    }
EOF
)"
fi

if is_enabled anytls; then
  add_inbound "$(cat <<EOF
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
    }
EOF
)"
fi

if is_enabled vmess; then
  add_inbound "$(cat <<EOF
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
    }
EOF
)"
fi

if is_enabled naive; then
  add_inbound "$(cat <<EOF
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
    }
EOF
)"
fi

if is_enabled wg; then
  add_endpoint "$(cat <<EOF
    {
      "type": "wireguard",
      "tag": "wg-ep",
      "address": ["10.0.0.1/32"],
      "private_key": "${WG_SERVER_PRIV}",
      "listen_port": ${WG_PORT},
      "peers": [
        {
          "public_key": "${WG_CLIENT_PUB}",
          "allowed_ips": ["0.0.0.0/0"]
        }
      ]
    }
EOF
)"
fi

if is_enabled mixed; then
  add_inbound "$(cat <<EOF
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "::",
      "listen_port": ${MIXED_PORT},
      "users": [{ "username": "${MIXED_USER}", "password": "${PASSWORD}" }]
    }
EOF
)"
fi

[ -n "$INBOUNDS" ] || die "DISABLE 关闭了所有协议，没什么可部署的"
cat > "$CONF/config.json" <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [${INBOUNDS}
  ],
  "endpoints": [${ENDPOINTS}
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

# ---- 预检配置 ----
log "预检 sing-box 配置…"
docker run --rm -v "$CONF:/etc/sing-box" "$IMAGE" check -c /etc/sing-box/config.json \
  || die "配置校验未通过"

# ---- 启动 ----
cd "$DIR"
docker compose up -d
sleep 3

# ---- 本机防火墙放行（只放行启用的协议）----
if command -v iptables >/dev/null 2>&1; then
  for spec in \
    "trojan:tcp:$TROJAN_PORT" "vless:tcp:$VLESS_PORT" "anytls:tcp:$ANYTLS_PORT" \
    "vmess:tcp:$VMESS_PORT" "naive:tcp:$NAIVE_PORT" "mixed:tcp:$MIXED_PORT" \
    "hy2:udp:$HY2_PORT" "tuic:udp:$TUIC_PORT" "wg:udp:$WG_PORT" \
    "ss:tcp:$SS_PORT" "ss:udp:$SS_PORT"; do
    key="${spec%%:*}"; rest="${spec#*:}"; proto="${rest%%:*}"; port="${rest#*:}"
    is_enabled "$key" || continue
    iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
  done
fi

docker ps --filter name=singbox-multi --format '{{.Status}}' | grep -qi up \
  || { docker logs singbox-multi --tail 30; die "容器未正常运行，见上方日志"; }

HOST="$(curl -fsSL --max-time 8 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"

# ---- 输出组装（只含启用的协议）----
SURGE_LINES=""; LINK_LINES=""; SURGE_NOTES=""; LISTEN_DESC=""; FW_TCP=""; FW_UDP=""
add_surge() { SURGE_LINES="${SURGE_LINES:+$SURGE_LINES
}$1"; }
add_link() { LINK_LINES="${LINK_LINES:+$LINK_LINES
}$1"; }
add_note() { SURGE_NOTES="${SURGE_NOTES:+$SURGE_NOTES
}$1"; }
add_listen() { LISTEN_DESC="${LISTEN_DESC:+$LISTEN_DESC / }$1"; }
add_fw() { # $1=tcp/udp $2=port
  if [ "$1" = tcp ]; then FW_TCP="${FW_TCP:+$FW_TCP,}$2"; else FW_UDP="${FW_UDP:+$FW_UDP,}$2"; fi
}

VMESS_LINK="vmess://$(echo -n "{\"v\":\"2\",\"ps\":\"MB-VMess\",\"add\":\"${HOST}\",\"port\":\"${VMESS_PORT}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"net\":\"tcp\",\"type\":\"none\",\"tls\":\"tls\",\"sni\":\"${SNI}\",\"allowInsecure\":1}" | base64 | tr -d '\n')"
SS_LINK="ss://$(echo -n "${SS_METHOD}:${SS_PASSWORD}" | base64 | tr -d '\n')@${HOST}:${SS_PORT}#MB-SS"

if is_enabled hy2; then
  add_listen "HY2 UDP ${HY2_PORT}"
  add_link "hysteria2://${PASSWORD}@${HOST}:${HY2_PORT}?sni=${SNI}&insecure=1#MB-HY2"
  add_note "# Hysteria2：Surge 仅基础支持，建议用下面的 hy2:// 链接导入或在 Egern 里配"
  add_fw udp "$HY2_PORT"
fi
if is_enabled tuic; then
  add_listen "TUIC UDP ${TUIC_PORT}"
  add_surge "MB-TUIC   = tuic-v5, ${HOST}, ${TUIC_PORT}, uuid=${UUID}, password=${PASSWORD}, sni=${SNI}, alpn=h3, skip-cert-verify=true"
  add_link "tuic://${UUID}:${PASSWORD}@${HOST}:${TUIC_PORT}?sni=${SNI}&alpn=h3&congestion_control=bbr#MB-TUIC"
  add_fw udp "$TUIC_PORT"
fi
if is_enabled trojan; then
  add_listen "Trojan TCP ${TROJAN_PORT}"
  add_surge "MB-TROJAN = trojan, ${HOST}, ${TROJAN_PORT}, password=${PASSWORD}, sni=${SNI}, skip-cert-verify=true"
  add_link "trojan://${PASSWORD}@${HOST}:${TROJAN_PORT}?sni=${SNI}&allowInsecure=1#MB-TROJAN"
  add_fw tcp "$TROJAN_PORT"
fi
if is_enabled vless; then
  add_listen "VLESS TCP ${VLESS_PORT}"
  add_link "vless://${UUID}@${HOST}:${VLESS_PORT}?security=tls&sni=${SNI}&allowInsecure=1#MB-VLESS"
  add_note "# VLESS：Surge 不支持，用 Egern（下面的 vless:// 链接）"
  add_fw tcp "$VLESS_PORT"
fi
if is_enabled ss; then
  add_listen "SS TCP+UDP ${SS_PORT}"
  add_surge "MB-SS     = ss, ${HOST}, ${SS_PORT}, encrypt-method=${SS_METHOD}, password=${SS_PASSWORD}, udp-relay=true"
  add_link "$SS_LINK"
  add_fw tcp "$SS_PORT"; add_fw udp "$SS_PORT"
fi
if is_enabled anytls; then
  add_listen "AnyTLS TCP ${ANYTLS_PORT}"
  add_link "anytls://${PASSWORD}@${HOST}:${ANYTLS_PORT}?sni=${SNI}&insecure=1#MB-AnyTLS"
  add_note "# AnyTLS：Surge/Egern 均支持，用下面的 anytls:// 链接导入"
  add_fw tcp "$ANYTLS_PORT"
fi
if is_enabled vmess; then
  add_listen "VMess TCP ${VMESS_PORT}"
  add_surge "MB-VMESS  = vmess, ${HOST}, ${VMESS_PORT}, username=${UUID}, tls=true, skip-cert-verify=true"
  add_link "$VMESS_LINK"
  add_fw tcp "$VMESS_PORT"
fi
if is_enabled naive; then
  add_listen "Naive TCP ${NAIVE_PORT}"
  add_note "# Naive：iOS 暂无客户端，用桌面端 sing-box"
  add_fw tcp "$NAIVE_PORT"
fi
if is_enabled wg; then
  add_listen "WireGuard UDP ${WG_PORT}"
  add_note "# WireGuard：用官方 WireGuard App 或 Egern，按下方参数填"
  add_fw udp "$WG_PORT"
fi
if is_enabled mixed; then
  add_listen "混合 TCP ${MIXED_PORT}"
  add_surge "MB-SOCKS  = socks5, ${HOST}, ${MIXED_PORT}, username=${MIXED_USER}, password=${PASSWORD}"
  add_fw tcp "$MIXED_PORT"
fi

WG_SECTION=""; NAIVE_SECTION=""
if is_enabled wg; then
WG_SECTION="$(cat <<EOF
----- WireGuard 参数（Egern / 官方 App）-----
  服务器：${HOST}    端口：${WG_PORT}（UDP）
  客户端地址：10.0.0.2/32
  客户端私钥：${WG_CLIENT_PRIV}
  服务端公钥：${WG_SERVER_PUB}
  允许 IP：0.0.0.0/0, ::/0

EOF
)"
fi
if is_enabled naive || is_enabled mixed; then
NAIVE_SECTION="$(cat <<EOF
----- Naive / 混合 原始参数 -----
EOF
)"
if is_enabled naive; then
NAIVE_SECTION="${NAIVE_SECTION}  Naive：${HOST}:${NAIVE_PORT}，用户名 ${MIXED_USER}，密码见下方，TLS SNI=${SNI}（跳过证书验证）
"
fi
if is_enabled mixed; then
NAIVE_SECTION="${NAIVE_SECTION}  混合：${HOST}:${MIXED_PORT}，HTTP/Socks5 通吃，用户名 ${MIXED_USER}

"
fi
fi

# 密码 / UUID 用途说明（按启用的协议动态生成）
PW_USE=""; UUID_USE=""
for p in hy2:HY2 trojan:Trojan tuic:TUIC anytls:AnyTLS naive:Naive mixed:混合; do
  if is_enabled "${p%%:*}"; then PW_USE="${PW_USE:+$PW_USE / }${p#*:}"; fi
done
for p in tuic:TUIC vless:VLESS vmess:VMess; do
  if is_enabled "${p%%:*}"; then UUID_USE="${UUID_USE:+$UUID_USE / }${p#*:}"; fi
done
UUID_LINE="  UUID：${UUID}"; [ -n "$UUID_USE" ] && UUID_LINE+="（${UUID_USE} 用）"
PW_LINE="  密码：${PASSWORD}"; [ -n "$PW_USE" ] && PW_LINE+="（${PW_USE} 用）"

cat <<DONE

======================================================================
 sing-box 多协议节点 (Docker) 部署完成
  监听：${LISTEN_DESC}
  镜像：${IMAGE}
  配置：${CONF}/config.json
  凭据：${META}
  运维：cd ${DIR} && docker compose {logs,restart,down}
  菜单：curl -fsSL <脚本URL> | bash -s menu（查看/改端口/换密码/开关协议等）
======================================================================

----- Surge 配置行（[Proxy]，直接粘贴）-----
${SURGE_LINES}
${SURGE_NOTES}

----- 通用链接（Egern / Shadowrocket 等粘贴导入）-----
${LINK_LINES}

${WG_SECTION}
${NAIVE_SECTION}
----- 原始参数 -----
  服务器：${HOST}
${UUID_LINE}
${PW_LINE}
  SS 密钥：${SS_PASSWORD}（base64，${SS_METHOD} 用）
  SNI：${SNI}
  证书：自签，客户端需开"跳过证书验证"
======================================================================
DONE
echo "云控制台必做：安全组放行 入站 TCP ${FW_TCP} 与 UDP ${FW_UDP}"
