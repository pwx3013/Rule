#!/bin/bash
# Trojan (TLS + WebSocket) 一键部署脚本 —— sing-box Docker 版
#
# 部署:     bash deploy-trojan-ws.sh
# 直接改配置（不用重跑安装）:
#   bash deploy-trojan-ws.sh info              查看节点信息
#   bash deploy-trojan-ws.sh set-port 8443     修改端口
#   bash deploy-trojan-ws.sh set-password      更换密码（随机）
#   bash deploy-trojan-ws.sh set-ws /xxx       修改 WS 路径
#   bash deploy-trojan-ws.sh set-sni example.com  修改 SNI（自动重签证书）
#   bash deploy-trojan-ws.sh restart           重启服务
#   bash deploy-trojan-ws.sh uninstall         卸载
#
# 环境变量覆盖默认值: TROJAN_PORT / WS_PATH / SNI / PASSWORD / RESET_PASSWORD=<redacted>
set -euo pipefail

DIR="/opt/trojan-ws"
CONF="$DIR/conf"
META="$CONF/meta.env"
IMAGE="ghcr.io/sagernet/sing-box:v1.14.2"

die() { echo "错误: $*" >&2; exit 1; }
log() { echo "[*] $*"; }

load_meta() {
  [ -f "$META" ] || die "未找到已部署配置（$META），请先执行部署"
  # shellcheck disable=SC1090
  source "$META"
}

fw_del() { iptables -D INPUT -p tcp --dport "$1" -j ACCEPT 2>/dev/null || true; }
fw_add() {
  iptables -C INPUT -p tcp --dport "$1" -j ACCEPT 2>/dev/null \
    || iptables -I INPUT -p tcp --dport "$1" -j ACCEPT 2>/dev/null || true
}

do_deploy() {
  command -v docker >/dev/null 2>&1 || die "未找到 docker，请先安装 docker"
  command -v openssl >/dev/null 2>&1 || die "未找到 openssl"
  mkdir -p "$CONF"

  # 读旧凭据（重复运行复用）
  if [ -f "$META" ]; then
    # shellcheck disable=SC1090
    source "$META"
  fi

  TROJAN_PORT="${TROJAN_PORT:-${TROJAN_PORT_SAVED:-34443}}"
  WS_PATH="${WS_PATH:-${WS_PATH_SAVED:-/trojan}}"
  SNI="${SNI:-${SNI_SAVED:-www.bing.com}}"
  if [ "${RESET_PASSWORD:-}" = "1" ]; then
    PASSWORD="$(openssl rand -hex 16)"
  else
    PASSWORD="${PASSWORD:-${PASSWORD_SAVED:-$(openssl rand -hex 16)}}"
  fi

  # 自签证书（SNI 变了就重签）
  if [ ! -f "$CONF/cert.pem" ] || [ "${SNI}" != "${SNI_SAVED:-}" ]; then
    log "生成自签证书 (CN=${SNI})…"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$CONF/key.pem" -out "$CONF/cert.pem" \
      -days 3650 -nodes -subj "/CN=${SNI}" 2>/dev/null
  fi

  # 写 sing-box 配置
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

  # 回写 meta.env
  cat > "$META" <<EOF
TROJAN_PORT_SAVED=${TROJAN_PORT}
WS_PATH_SAVED=${WS_PATH}
SNI_SAVED=${SNI}
PASSWORD_SAVED=${PASSWORD}
EOF
  chmod 600 "$META"

  # 校验配置
  log "校验配置…"
  docker run --rm -v "$CONF:/etc/sing-box" "$IMAGE" check -c /etc/sing-box/config.json

  # 启动容器
  docker rm -f trojan-ws 2>/dev/null || true
  docker run -d --name trojan-ws --restart unless-stopped --network host \
    -v "$CONF:/etc/sing-box" \
    "$IMAGE" run -c /etc/sing-box/config.json
  sleep 2
  docker ps --filter name=trojan-ws --format '{{.Status}}' | grep -qi up \
    || { docker logs trojan-ws --tail 20; die "容器未正常运行"; }

  # 放行防火墙
  command -v iptables >/dev/null 2>&1 && fw_add "$TROJAN_PORT" || true

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
}

cmd_info() {
  load_meta
  echo "---------- Trojan WS+TLS ----------"
  echo "  端口:    ${TROJAN_PORT_SAVED:-?} (TCP)"
  echo "  密码:    ${PASSWORD_SAVED:-?}"
  echo "  WS 路径: ${WS_PATH_SAVED:-/trojan}"
  echo "  SNI:     ${SNI_SAVED:-www.bing.com}（自签证书）"
}

cmd_set_port() {
  local p="${1:-}"
  [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || die "用法: $0 set-port <1-65535>"
  load_meta
  local old="${TROJAN_PORT_SAVED:-34443}"
  if [ "$p" = "$old" ]; then echo "端口未变"; return 0; fi
  command -v iptables >/dev/null 2>&1 && fw_del "$old" || true
  TROJAN_PORT="$p" do_deploy
}

cmd_set_password() {
  load_meta
  RESET_PASSWORD=1 do_deploy
}

cmd_set_ws() {
  local w="${1:-}"
  [ -n "$w" ] || die "用法: $0 set-ws <路径，如 /trojan>"
  [[ "$w" == /* ]] || die "WS 路径必须以 / 开头"
  WS_PATH="$w" do_deploy
}

cmd_set_sni() {
  local s="${1:-}"
  [ -n "$s" ] || die "用法: $0 set-sni <域名>"
  SNI="$s" do_deploy
}

cmd_restart() {
  docker restart trojan-ws >/dev/null 2>&1 && echo "服务已重启" || die "重启失败（容器不存在？）"
}

cmd_uninstall() {
  load_meta 2>/dev/null || true
  docker rm -f trojan-ws 2>/dev/null || true
  command -v iptables >/dev/null 2>&1 && fw_del "${TROJAN_PORT_SAVED:-34443}" || true
  rm -rf "$DIR"
  echo "已卸载（含配置与密码）。镜像保留，需要可手动 docker rmi $IMAGE"
}

usage() {
  sed -n '2,13p' "$0"
}

case "${1:-}" in
  "") do_deploy;;
  info) cmd_info;;
  set-port) cmd_set_port "${2:-}";;
  set-password) cmd_set_password;;
  set-ws) cmd_set_ws "${2:-}";;
  set-sni) cmd_set_sni "${2:-}";;
  restart) cmd_restart;;
  uninstall) cmd_uninstall;;
  -h|--help|help) usage;;
  *) die "未知命令: $1"; usage;;
esac
