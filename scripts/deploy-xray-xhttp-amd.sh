#!/usr/bin/env bash
# Xray-core VLESS + XHTTP (TLS) 一键部署 — 圣何塞AMD (192.9.146.146)
# 域名: lovey1314.eu.org, 端口: 8443, XHTTP path: /xhttp, mode: auto
# 用法( root, Termius 里跑 ): bash deploy-xray-xhttp-amd.sh
# UUID 在本机现生成、不进仓库, 跑完脚本最后会打印导入链接
#
# CF 优选 IP 用法:
#   1. 申证书时域名必须是 DNS-only(灰云)且 A 记录指到本机, 脚本开头会校验,
#      已是橙云就先切回灰云再跑, 跑完再切回橙云.
#   2. 跑完后去 CF 把 lovey1314.eu.org 改成橙云代理(Proxied), 8443 是 CF 支持的
#      HTTPS 端口, 之后客户端地址填 CF 优选 IP、端口 8443、SNI/Host 填域名就能走 CF.
#   3. 证书续期: acme.sh standalone 需 80 端口直连本机, 橙云下续期会失败,
#      到期前切回灰云跑一次 /root/.acme.sh/acme.sh --renew -d lovey1314.eu.org
#      再切回橙云; 或改用 CF DNS API 方式续期.
set -euo pipefail

DOMAIN="lovey1314.eu.org"
PORT=8443
XHTTP_PATH="/xhttp"
XRAY_CONF="/usr/local/etc/xray/config.json"
CERT_DIR="/usr/local/etc/xray/cert"

[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行"; exit 1; }

# 端口占用检查
for p in 80 "$PORT"; do
  if ss -tlnp 2>/dev/null | grep -q ":$p "; then echo "端口 $p 已被占用, 先停掉占用它的服务再跑"; exit 1; fi
done

# 域名解析检查: 必须解析到本机公网 IP, 橙云代理下 HTTP-01 申证书会失败
PUB_IP=$(curl -fsS4 https://ifconfig.me)
DOM_IP=$(getent hosts "$DOMAIN" | awk '$1 ~ /^[0-9.]+$/ {print $1}' | head -n1)
[ -n "$DOM_IP" ] && [ "$DOM_IP" = "$PUB_IP" ] || { echo "域名 $DOMAIN 解析到 ${DOM_IP:-<无结果>}, 本机公网 IP 是 $PUB_IP, 先把 A 记录指到本机并改成 DNS-only(灰云)再跑"; exit 1; }

apt-get update -qq
apt-get install -y -qq curl socat cron ca-certificates

# 安装 Xray-core
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# acme.sh 申请证书 (standalone, 临时占 80 端口)
export HOME=/root
if [ ! -x /root/.acme.sh/acme.sh ]; then
  curl https://get.acme.sh | sh -s email=admin@lovey1314.eu.org
fi
/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
mkdir -p "$CERT_DIR"
/root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone
/root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file "$CERT_DIR/private.key" \
  --fullchain-file "$CERT_DIR/fullchain.crt" \
  --reloadcmd "systemctl restart xray"

UUID=$(cat /proc/sys/kernel/random/uuid)

mkdir -p /usr/local/etc/xray
cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$UUID" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "xhttpSettings": { "path": "$XHTTP_PATH", "mode": "auto" },
        "tlsSettings": {
          "certificates": [
            { "certificateFile": "$CERT_DIR/fullchain.crt", "keyFile": "$CERT_DIR/private.key" }
          ]
        }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

systemctl enable xray
systemctl restart xray
sleep 2
systemctl is-active --quiet xray || { echo "xray 启动失败, 看日志: journalctl -u xray -n 50"; exit 1; }
ss -tlnp | grep -q ":$PORT " || { echo "端口 $PORT 没起来"; exit 1; }

echo
echo "部署完成, 直连导入链接:"
echo "vless://$UUID@$DOMAIN:$PORT?encryption=none&security=tls&sni=$DOMAIN&type=xhttp&path=%2Fxhttp&mode=auto#AMD-XHTTP"
echo
echo "走 CF 优选 IP: 先去 CF 把 $DOMAIN 改成橙云代理, 再把上面链接里的 $DOMAIN"
echo "换成任一 CF 优选 IP(端口不变, 仍是 $PORT, SNI 已带域名不用改), 例如:"
echo "vless://$UUID@<CF优选IP>:$PORT?encryption=none&security=tls&sni=$DOMAIN&type=xhttp&path=%2Fxhttp&mode=auto&host=$DOMAIN#AMD-XHTTP-CF"
