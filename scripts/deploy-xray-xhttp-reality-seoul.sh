#!/usr/bin/env bash
# Xray-core VLESS + XHTTP + REALITY — 首尔AMD (193.123.232.158)
# 在现有 XHTTP(经 Caddy 443)之外, 另加一个 Xray 直连入站: VLESS + XHTTP + REALITY
# REALITY 必须由 Xray 直接监听公网端口做握手, 不能走 Caddy, 所以单独占一个端口 (默认 8443)
# 客户端直连 VPS 公网 IP:端口 (不走 CF), SNI=REALITY 目标站, 需云安全组放行 TCP 端口
# 用法( root, Termius 里跑 ):
#   bash deploy-xray-xhttp-reality-seoul.sh
#   REALITY_PORT=8443 REALITY_SNI=www.ebay.com bash deploy-xray-xhttp-reality-seoul.sh
# REALITY 目标站须支持 TLS 1.3 + HTTP/2 (XHTTP 要求); XHTTP 下不要开 Mux
set -euo pipefail

XRAY_CONF="/usr/local/etc/xray/config.json"
REALITY_PORT="${REALITY_PORT:-8443}"
REALITY_SNI="${REALITY_SNI:-www.ebay.com}"
VPS_IP="193.123.232.158"

[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行"; exit 1; }
command -v xray >/dev/null || { echo "没找到 xray, 先确认 Xray 已安装"; exit 1; }
[ -f "$XRAY_CONF" ] || { echo "没找到 $XRAY_CONF"; exit 1; }
command -v python3 >/dev/null || { echo "没找到 python3"; exit 1; }
command -v openssl >/dev/null || { echo "没找到 openssl"; exit 1; }

if grep -q '"security": "reality"' "$XRAY_CONF"; then
  echo "配置里已有 REALITY 入站, 不再重复添加"; exit 1
fi
if ss -tlnp 2>/dev/null | grep -q ":$REALITY_PORT "; then
  echo "端口 $REALITY_PORT 已被占用, 换个 REALITY_PORT 再跑"; exit 1
fi

# 沿用现有 XHTTP 入站的 UUID, 没有就现生成
UUID=$(grep -oP '"id":\s*"\K[^"]+' "$XRAY_CONF" | head -n1 || true)
[ -n "$UUID" ] || UUID=$(cat /proc/sys/kernel/random/uuid)

# 生成 REALITY x25519 密钥对
KEYS=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | sed -n 's/^Private key: //p')
PUBLIC_KEY=$(echo "$KEYS" | sed -n 's/^Public key: //p')
[ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] || { echo "xray x25519 生成密钥失败"; exit 1; }

SID=$(openssl rand -hex 4)
XPATH="/$(openssl rand -hex 8)"

# 用 python3 安全地往 inbounds 追加一个 REALITY+XHTTP 入站
python3 - "$XRAY_CONF" "$REALITY_PORT" "$REALITY_SNI" "$PRIVATE_KEY" "$SID" "$XPATH" "$UUID" <<'PYEOF'
import json, sys
conf_path, port, sni, priv, sid, xpath, uuid = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7]
with open(conf_path) as f:
    cfg = json.load(f)
new_inbound = {
  "listen": "0.0.0.0",
  "port": port,
  "protocol": "vless",
  "settings": {"clients": [{"id": uuid}], "decryption": "none"},
  "streamSettings": {
    "network": "xhttp",
    "security": "reality",
    "realitySettings": {
      "show": False,
      "dest": f"{sni}:443",
      "xver": 0,
      "serverNames": [sni],
      "privateKey": priv,
      "shortIds": [sid]
    },
    "xhttpSettings": {"path": xpath, "mode": "auto"}
  }
}
cfg.setdefault("inbounds", []).append(new_inbound)
with open(conf_path, "w") as f:
    json.dump(cfg, f, indent=2)
print("已追加 REALITY+XHTTP 入站")
PYEOF

xray -test -config "$XRAY_CONF" || { echo "Xray 配置校验失败, 看上面报错"; exit 1; }

systemctl enable xray
systemctl restart xray
sleep 2
systemctl is-active --quiet xray || { echo "xray 启动失败, 看日志: journalctl -u xray -n 50"; exit 1; }

# path 的 / 要编码成 %2F
ENCODED_PATH="%2F${XPATH#/}"
echo
echo "部署完成, REALITY+XHTTP 导入链接 (直连 VPS IP, 不走 CF):"
echo "vless://$UUID@$VPS_IP:$REALITY_PORT?encryption=none&security=reality&sni=$REALITY_SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SID&type=xhttp&path=$ENCODED_PATH&mode=auto#Seoul-XHTTP-Reality"
echo
echo "注意:"
echo "- 云安全组放行 TCP $REALITY_PORT, 否则连不上"
echo "- XHTTP 下不要开 Mux"
echo "- 原有 Caddy 443 的 XHTTP 节点不受影响, 两个节点可并存"
