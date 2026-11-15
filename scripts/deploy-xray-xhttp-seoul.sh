#!/usr/bin/env bash
# Xray-core VLESS + XHTTP 一键部署 — 首尔AMD (193.123.232.158)
# 域名: qiaosan.eu.org, 端口: 443, XHTTP path: /xhttp, mode: auto
#
# 方案: Caddy(233boy 自动 TLS, 占 80/443)在 443 站点里加 /xhttp 反代 -> 本地 Xray(127.0.0.1:10086, 明文 XHTTP)
#   - 证书继续由 Caddy 管, 不用再申
#   - 往 /etc/caddy/233boy/qiaosan.eu.org.conf.add 里加路由(这个文件就是留给用户追加的),
#     不动主 Caddyfile; 只有测通 XHTTP 后才删旧 WS 路由
#   - Trojan 已不用, 旧 WS 路由(/b1e61b1e-... -> 127.0.0.1:52552)测通后删掉
#   - Caddy 重载: 先 reload, 不行(Admin 关了时)再 restart
# 用法( root, Termius 里跑 ): bash deploy-xray-xhttp-seoul.sh
# UUID 在本机现生成、不进仓库; 重跑脚本会沿用已生成的 UUID, 跑完打印导入链接
set -euo pipefail

DOMAIN="qiaosan.eu.org"
PORT=443
LOCAL_PORT=10086
XHTTP_PATH="/xhttp"
XRAY_CONF="/usr/local/etc/xray/config.json"
CADDY_ADD="/etc/caddy/233boy/qiaosan.eu.org.conf.add"
CADDY_SITE="/etc/caddy/233boy/qiaosan.eu.org.conf"

[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行"; exit 1; }

command -v caddy >/dev/null || { echo "没找到 caddy, 先确认 Caddy 已安装"; exit 1; }
systemctl is-active --quiet caddy || { echo "caddy 服务没在跑, 先启动它再跑"; exit 1; }
[ -f "$CADDY_ADD" ] || { echo "没找到 $CADDY_ADD"; exit 1; }
[ -f "$CADDY_SITE" ] || { echo "没找到 $CADDY_SITE"; exit 1; }

# 本地端口占用检查(重跑时已是自己占用的端口就跳过)
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

# Caddy 443 站点加 /xhttp 路由: 写进 .add 文件(留给用户追加的), 不动主 Caddyfile 和 .conf 本体
# 注意: 匹配器必须是 $XHTTP_PATH* (前缀匹配)——XHTTP 会话路径是 /xhttp/<会话UUID> 与
# /xhttp/<会话UUID>/<序号>, 只写 /xhttp 时 Caddy 只匹配精确路径, 真实会话全被挡在外面
if ! grep -q "reverse_proxy ${XHTTP_PATH}\*" "$CADDY_ADD"; then
  cat >> "$CADDY_ADD" <<EOF

    reverse_proxy ${XHTTP_PATH}* 127.0.0.1:$LOCAL_PORT {
        flush_interval -1
    }
EOF
fi

caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile || { echo "Caddy 配置校验失败, 已停下, 新加的路由未生效"; exit 1; }

systemctl enable xray
systemctl restart xray
sleep 2
systemctl is-active --quiet xray || { echo "xray 启动失败, 看日志: journalctl -u xray -n 50"; exit 1; }

systemctl reload caddy || systemctl restart caddy
sleep 2
systemctl is-active --quiet caddy || { echo "caddy 重载/重启后异常, 看日志: journalctl -u caddy -n 50"; exit 1; }

# 链路自检: 经 Caddy 请求一次 /xhttp, 只要拿到 HTTP 状态码就说明通了
CODE=$(curl -sk --resolve "$DOMAIN:$PORT:127.0.0.1" "https://$DOMAIN:$PORT$XHTTP_PATH" -o /dev/null -w "%{http_code}" || true)
echo "链路自检: https://$DOMAIN:$PORT$XHTTP_PATH 返回 HTTP $CODE (400/404 都算通, 000 才是不通)"

# 测通后才删旧 WS 路由(Trojan 已不用): 删 .conf 里指向 127.0.0.1:52552 的那行
if [ "$CODE" != "000" ] && [ -n "$CODE" ]; then
  cp "$CADDY_SITE" "$CADDY_SITE.bak"
  sed -i '/127\.0\.0\.1:52552/d' "$CADDY_SITE"
  if caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; then
    systemctl reload caddy || systemctl restart caddy
    echo "旧 WS 路由已删(备份在 $CADDY_SITE.bak), 443 现在只有 XHTTP"
  else
    echo "删 WS 路由后校验失败, 已恢复备份"
    cp "$CADDY_SITE.bak" "$CADDY_SITE"
    systemctl reload caddy || systemctl restart caddy
  fi
else
  echo "XHTTP 未通(000), 旧 WS 路由保留, 先排查再手动删"
fi

echo
echo "部署完成, 直连导入链接:"
echo "vless://$UUID@$DOMAIN:$PORT?encryption=none&security=tls&sni=$DOMAIN&type=xhttp&path=%2Fxhttp&mode=auto#Seoul-XHTTP"
echo
echo "走 CF 优选 IP: 把上面链接里的 $DOMAIN 换成任一 CF 优选 IP(端口不变, 仍是 $PORT, sni 保持 $DOMAIN)"
echo "sing-box 里的 WS 配置(52552)已无流量, 可在 sb 菜单里删掉, 不删也无害"
