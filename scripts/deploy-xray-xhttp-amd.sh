#!/usr/bin/env bash
# Xray-core VLESS + XHTTP 一键部署 — 圣何塞AMD (192.9.146.146)
# 域名: lovey1314.eu.org, 端口: 8443, XHTTP path: /xhttp, mode: auto
#
# 方案: Caddy(233boy 自动 TLS, v2.11.9, 占 80/443)反代 8443 -> 本地 Xray(127.0.0.1:10086, 明文 XHTTP)
#   - 证书继续由 Caddy 管, 不用再申, 不占 80 端口
#   - Trojan(443, Caddy 反代 /066da886-... 到 sing-box 127.0.0.1:31211)不受影响
#   - 主 Caddyfile 写明不要编辑, 不动它; 只在 /etc/caddy/sites/ 里加站点文件
#   - Caddy 重载: 先 reload, 不行(Admin 关了时)再 restart, Trojan 只闪断一下
# 用法( root, Termius 里跑 ): bash deploy-xray-xhttp-amd.sh
# UUID 在本机现生成、不进仓库; 重跑脚本会沿用已生成的 UUID, 跑完打印导入链接
set -euo pipefail

DOMAIN="lovey1314.eu.org"
PORT=8443
LOCAL_PORT=10086
XHTTP_PATH="/xhttp"
XRAY_CONF="/usr/local/etc/xray/config.json"
CADDY_SITE="/etc/caddy/sites/xhttp-8443.conf"

[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行"; exit 1; }

command -v caddy >/dev/null || { echo "没找到 caddy, 先确认 Caddy 已安装"; exit 1; }
systemctl is-active --quiet caddy || { echo "caddy 服务没在跑, 先启动它再跑"; exit 1; }
[ -d /etc/caddy/sites ] || { echo "没找到 /etc/caddy/sites 目录"; exit 1; }

# 端口占用检查(重跑时已是自己占用的端口就跳过)
if [ ! -f "$CADDY_SITE" ] && ss -tlnp 2>/dev/null | grep -q ":$PORT "; then
  echo "端口 $PORT 已被占用, 先处理再跑"; exit 1
fi
if [ ! -f "$XRAY_CONF" ] && ss -tlnp 2>/dev/null | grep -q ":$LOCAL_PORT "; then
  echo "端口 $LOCAL_PORT 已被占用, 先处理再跑"; exit 1
fi

apt-get update -qq
apt-get install -y -qq curl ca-certificates unzip

# 安装 Xray-core
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 沿用已生成的 UUID, 没有就现生成
UUID=""
if [ -f "$XRAY_CONF" ]; then
  UUID=$(grep -oP '"id":\s*"\K[^"]+' "$XRAY_CONF" | head -n1 || true)
fi
[ -n "$UUID" ] || UUID=$(cat /proc/sys/kernel/random/uuid)

mkdir -p /usr/local/etc/xray
cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": $LOCAL_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$UUID" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": { "path": "$XHTTP_PATH", "mode": "auto" }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

# Caddy 加 8443 站点: 只在 sites/ 里加文件, 不动主 Caddyfile 和 233boy/ 的配置
# 注意: 匹配器必须是 $XHTTP_PATH* (前缀匹配)——XHTTP 会话路径是 /xhttp/<会话UUID> 与
# /xhttp/<会话UUID>/<序号>, 只写 /xhttp 时 Caddy 只匹配精确路径, 真实会话全被挡在外面
# (2026-11-06 实测: Egern 的请求已到 Caddy, 但 uri 是 /xhttp/ae481c82-.../0, Caddy 记 NOP、状态 0)
cat > "$CADDY_SITE" <<EOF
$DOMAIN:$PORT {
    reverse_proxy ${XHTTP_PATH}* 127.0.0.1:$LOCAL_PORT {
        flush_interval -1
    }
}
EOF

caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile || { echo "Caddy 配置校验失败, 已停下, 新加的站点文件未生效"; rm -f "$CADDY_SITE"; exit 1; }

systemctl enable xray
systemctl restart xray
sleep 2
systemctl is-active --quiet xray || { echo "xray 启动失败, 看日志: journalctl -u xray -n 50"; exit 1; }

systemctl reload caddy || systemctl restart caddy
sleep 2
systemctl is-active --quiet caddy || { echo "caddy 重载/重启后异常, 看日志: journalctl -u caddy -n 50"; exit 1; }
ss -tlnp | grep -q ":$PORT " || { echo "端口 $PORT 没起来"; exit 1; }

# 链路自检: 经 Caddy 请求一次 /xhttp, 只要拿到 HTTP 状态码就说明通了
CODE=$(curl -sk --resolve "$DOMAIN:$PORT:127.0.0.1" "https://$DOMAIN:$PORT$XHTTP_PATH" -o /dev/null -w "%{http_code}" || true)
echo "链路自检: https://$DOMAIN:$PORT$XHTTP_PATH 返回 HTTP $CODE (400/404 都算通, 000 才是不通)"

echo
echo "部署完成, 直连导入链接:"
echo "vless://$UUID@$DOMAIN:$PORT?encryption=none&security=tls&sni=$DOMAIN&type=xhttp&path=%2Fxhttp&mode=auto#AMD-XHTTP"
echo
echo "走 CF 优选 IP: 把域名改回橙云代理, 再把上面链接里的 $DOMAIN 换成任一 CF 优选 IP(端口不变, 仍是 $PORT)"
