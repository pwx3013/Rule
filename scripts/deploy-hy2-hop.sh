#!/usr/bin/env bash
# ==============================================================================
# Hysteria2 + 端口跳跃 一键部署脚本
# 适用: Oracle Cloud / 任意 x86_64 / aarch64 Linux (Oracle Linux / Ubuntu / Debian)
# 用法: sudo bash deploy-hy2-hop.sh
# 可选环境变量覆盖默认值:
#   HY2_PORT      主端口 (默认 8445; 避开 443/8443 已被 MASQUE 占用)
#   HOP_RANGE     跳跃端口段 (默认 20000-30000)
#   HY2_PASSWORD  认证密码 (默认随机生成)
#   HOP_INTERVAL  客户端建议的跳跃间隔秒数 (默认 30, 仅用于打印客户端配置)
#   HY2_IP        公网 IP (默认自动检测; 检测失败时须用此变量指定)
# 跑完后记得在云控制台安全组/安全列表放行 UDP: 主端口 + 跳跃端口段
# ==============================================================================
set -euo pipefail

HY2_PORT="${HY2_PORT:-8445}"
HOP_RANGE="${HOP_RANGE:-20000-30000}"
HY2_PASSWORD="${HY2_PASSWORD:-}"
HOP_INTERVAL="${HOP_INTERVAL:-30}"

# ---- 0. 必须是 root ----
if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行: sudo bash $0"
  exit 1
fi

# ---- 1. 架构与系统信息 ----
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  HY2_ARCH="amd64" ;;
  aarch64|arm64) HY2_ARCH="arm64" ;;
  *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac

if [[ -f /etc/os-release ]]; then . /etc/os-release; OS_ID="${ID:-unknown}"; else OS_ID="unknown"; fi
echo "==> 系统: ${OS_ID:-unknown} / $ARCH"

# ---- 2. 端口冲突检查 ----
port_in_use() { ss -uln 2>/dev/null | grep -qE "[: ]$1( |$)"; }
if port_in_use "$HY2_PORT"; then
  echo "!! UDP 端口 $HY2_PORT 已被占用, 请换一个: HY2_PORT=xxxx sudo bash $0"
  exit 1
fi
HOP_START="${HOP_RANGE%-*}"; HOP_END="${HOP_RANGE#*-}"
for p in "$HOP_START" "$HOP_END"; do
  if port_in_use "$p"; then echo "!! 跳跃段端点 UDP $p 已被占用, 请调整 HOP_RANGE"; exit 1; fi
done

# ---- 3. 安装依赖 ----
echo "==> 安装依赖 (curl/openssl) ..."
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq curl openssl ca-certificates >/dev/null
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y -q curl openssl ca-certificates >/dev/null
elif command -v yum >/dev/null 2>&1; then
  yum install -y -q curl openssl ca-certificates >/dev/null
fi

# ---- 4. 下载 hysteria2 最新版 ----
# 若 /usr/local/bin/hysteria 已存在且可运行, 则跳过下载
if [[ -x /usr/local/bin/hysteria ]] && /usr/local/bin/hysteria version >/dev/null 2>&1; then
  echo "==> 检测到已安装的 hysteria, 跳过下载"
  HY2_VER="$(/usr/local/bin/hysteria version 2>/dev/null | head -n1)"
else
  ASSET="hysteria-linux-${HY2_ARCH}"
  DL_OK=0
  try_download() { # $1 = url
    echo "    尝试: $1"
    if curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 20 --max-time 300 \
        -o /tmp/hysteria "$1"; then
      chmod +x /tmp/hysteria && DL_OK=1 && return 0
    fi
    echo "    下载失败 (curl 退出码 $?)"
    return 1
  }
  echo "==> 下载 Hysteria2 最新版 (${ASSET}) ..."
  try_download "https://github.com/apernet/hysteria/releases/latest/download/${ASSET}" || {
    echo "==> 主下载链失败, 改用 GitHub API 定位版本后重试 ..."
    TAG="$(curl -fsSL --connect-timeout 20 \
      https://api.github.com/repos/apernet/hysteria/releases/latest \
      | grep -oP '"tag_name":\s*"\K[^"]+' | head -n1 || true)"
    if [[ -n "$TAG" ]]; then
      echo "    最新版本: ${TAG}"
      try_download "https://github.com/apernet/hysteria/releases/download/${TAG}/${ASSET}" || true
    else
      echo "    GitHub API 请求也失败了"
    fi
  }
  if [[ $DL_OK -ne 1 ]]; then
    echo "!! hysteria 下载失败: 该机器连 github.com 下载 releases 有问题。"
    echo "   手动解决办法: 在能上网的电脑下载 ${ASSET}"
    echo "   (https://github.com/apernet/hysteria/releases/latest),"
    echo "   传到 VPS 的 /usr/local/bin/hysteria 并 chmod +x, 然后重跑本脚本即可跳过下载。"
    exit 1
  fi
  install -m 0755 /tmp/hysteria /usr/local/bin/hysteria
  HY2_VER="$(/usr/local/bin/hysteria version 2>/dev/null | head -n1 || true)"
  [[ -n "$HY2_VER" ]] || HY2_VER="hysteria (版本未知)"
fi
echo "==> ${HY2_VER}" | head -n1

# ---- 5. 生成密码与自签证书 ----
[[ -n "$HY2_PASSWORD" ]] || HY2_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
PUB_IP="${HY2_IP:-$(curl -fsSL --max-time 10 https://api.ipify.org || curl -fsSL --max-time 10 https://ifconfig.me || echo '')}"
[[ -n "$PUB_IP" ]] || { echo "!! 检测公网 IP 失败, 请用 HY2_IP=你的公网IP 指定"; exit 1; }

mkdir -p /etc/hysteria
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
  -days 3650 -subj "/CN=${PUB_IP}" >/dev/null 2>&1
chmod 600 /etc/hysteria/server.key
FP="$(openssl x509 -in /etc/hysteria/server.crt -noout -fingerprint -sha256 \
  | sed 's/.*=//; s/://g')"
echo "==> 证书指纹: $FP"

# ---- 6. 写服务端配置 ----
cat > /etc/hysteria/config.yaml <<EOF
# Hysteria2 + 端口跳跃 (由 deploy-hy2-hop.sh 生成, ${HY2_VER})
listen: 0.0.0.0:${HY2_PORT}

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: ${HY2_PASSWORD}

# 跳跃端口由防火墙 DNAT 到主端口, 服务端无需额外配置。
# 客户端每 ${HOP_INTERVAL}s 换一次端口, 建议带宽按需调整:
bandwidth:
  up: 100 mbps
  down: 500 mbps

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true

ignoreClientBandwidth: false
EOF
chmod 600 /etc/hysteria/config.yaml

# ---- 7. 端口跳跃: 防火墙 DNAT (nftables 优先, 其次 iptables) ----
apply_hop_rules() {
  if command -v nft >/dev/null 2>&1; then
    # 幂等: 先删旧表再建
    nft delete table ip hy2hop 2>/dev/null || true
    nft add table ip hy2hop
    nft 'add chain ip hy2hop prerouting { type nat hook prerouting priority dstnat; policy accept; }'
    nft add rule ip hy2hop prerouting udp dport "${HOP_START}-${HOP_END}" redirect to :"${HY2_PORT}"
    return 0
  elif command -v iptables >/dev/null 2>&1; then
    iptables -t nat -D PREROUTING -p udp --dport "${HOP_START}:${HOP_END}" \
      -j REDIRECT --to-ports "${HY2_PORT}" 2>/dev/null || true
    iptables -t nat -A PREROUTING -p udp --dport "${HOP_START}:${HOP_END}" \
      -j REDIRECT --to-ports "${HY2_PORT}"
    return 0
  fi
  return 1
}

echo "==> 配置端口跳跃 DNAT: UDP ${HOP_START}-${HOP_END} -> ${HY2_PORT} ..."
if apply_hop_rules; then
  echo "==> 跳跃规则已生效"
else
  echo "!! 未找到 nft/iptables, 跳跃规则未配置, 请手动做 UDP 端口转发"
fi

# ---- 8. 跳跃规则开机持久化 ----
# 方案: 独立 systemd oneshot, 开机自动重建规则 (不依赖发行版 nftables/iptables 服务)
cat > /usr/local/bin/hy2-hop-apply.sh <<EOF
#!/usr/bin/env bash
# 重建 hy2 端口跳跃 DNAT 规则 (hy2-hop.service 调用)
set -euo pipefail
if command -v nft >/dev/null 2>&1; then
  nft delete table ip hy2hop 2>/dev/null || true
  nft add table ip hy2hop
  nft 'add chain ip hy2hop prerouting { type nat hook prerouting priority dstnat; policy accept; }'
  nft add rule ip hy2hop prerouting udp dport ${HOP_START}-${HOP_END} redirect to :${HY2_PORT}
elif command -v iptables >/dev/null 2>&1; then
  iptables -t nat -C PREROUTING -p udp --dport ${HOP_START}:${HOP_END} \
    -j REDIRECT --to-ports ${HY2_PORT} 2>/dev/null || \
  iptables -t nat -A PREROUTING -p udp --dport ${HOP_START}:${HOP_END} \
    -j REDIRECT --to-ports ${HY2_PORT}
fi
EOF
chmod +x /usr/local/bin/hy2-hop-apply.sh

cat > /etc/systemd/system/hy2-hop.service <<EOF
[Unit]
Description=Hysteria2 port hopping NAT rules
After=network-online.target
Wants=network-online.target
Before=hysteria.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/hy2-hop-apply.sh

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now hy2-hop.service >/dev/null

# ---- 9. 本机防火墙放行 UDP 主端口 + 跳跃段 ----
echo "==> 本机防火墙放行 UDP ${HY2_PORT} 与 ${HOP_START}-${HOP_END} ..."
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
  firewall-cmd --permanent --add-port="${HY2_PORT}/udp" >/dev/null
  firewall-cmd --permanent --add-port="${HOP_START}-${HOP_END}/udp" >/dev/null
  firewall-cmd --reload >/dev/null
  echo "    (firewalld 已放行)"
elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${HY2_PORT}/udp" >/dev/null
  ufw allow "${HOP_START}:${HOP_END}/udp" >/dev/null
  echo "    (ufw 已放行)"
else
  echo "    (未检测到启用的 firewalld/ufw, 如有其他防火墙请手动放行)"
fi

# ---- 10. hysteria systemd 服务 ----
cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria2 Server (port hopping)
After=network-online.target hy2-hop.service
Wants=network-online.target
Requires=hy2-hop.service

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now hysteria.service >/dev/null
sleep 2

# ---- 11. 状态检查 ----
echo ""
if systemctl is-active --quiet hysteria.service; then
  echo "==> hysteria 运行中 ✓"
else
  echo "!! hysteria 启动失败, 查看日志: journalctl -u hysteria -e --no-pager"
  exit 1
fi
ss -uln | grep -E ":${HY2_PORT} " >/dev/null && echo "==> UDP ${HY2_PORT} 监听正常 ✓"
echo "==> 跳跃规则:"
if command -v nft >/dev/null 2>&1; then
  nft list table ip hy2hop 2>/dev/null | grep -E "dport|redirect" || true
elif command -v iptables >/dev/null 2>&1; then
  iptables -t nat -L PREROUTING -n | grep -E "${HY2_PORT}|${HOP_START}" || true
fi

# ---- 12. 输出客户端信息 ----
INFO_FILE="/etc/hysteria/client-info.txt"
cat > "$INFO_FILE" <<EOF
================ Hysteria2 + 端口跳跃 =================
服务端版本 : ${HY2_VER}
服务器 IP  : ${PUB_IP}
主端口     : ${HY2_PORT} (UDP)
跳跃端口段 : ${HOP_START}-${HOP_END} (UDP, DNAT 到主端口)
认证密码   : ${HY2_PASSWORD}
证书指纹   : ${FP}
跳跃间隔   : ${HOP_INTERVAL}s (客户端设置)

---- Egern 配置片段 (加到 proxies: 下) ----
- hysteria2:
    name: hy2-hop
    server: ${PUB_IP}
    port: ${HY2_PORT}
    auth: ${HY2_PASSWORD}
    sni: ${PUB_IP}
    fingerprint_sha256: ${FP}
    port_hopping: ${HY2_PORT},${HOP_START}-${HOP_END}
    port_hopping_interval: ${HOP_INTERVAL}

---- 通用 hy2:// 链接 (v2rayNG / Nekoray 等, 多端口逗号分隔) ----
hysteria2://${HY2_PASSWORD}@${PUB_IP}:${HY2_PORT},${HOP_START}-${HOP_END}/?sni=${PUB_IP}&insecure=1#hy2-hop

---- 备注 ----
1. Oracle Cloud 控制台「安全列表/安全组」必须放行 UDP ${HY2_PORT} 和 UDP ${HOP_START}-${HOP_END} 入站,
   否则跳跃端口进不来。
2. 证书是自签的, Egern 用 fingerprint_sha256 pin 住指纹即可 (已填好);
   其他客户端可用 insecure=1 跳过校验 (安全性略降, 但有密码认证)。
3. 想改端口/密码: 编辑 /etc/hysteria/config.yaml 后
   systemctl restart hysteria; 改跳跃段需同步改 /usr/local/bin/hy2-hop-apply.sh
   里的端口并 systemctl restart hy2-hop。
4. 卸载: systemctl disable --now hysteria hy2-hop; rm -rf /etc/hysteria \
   /etc/systemd/system/hysteria.service /etc/systemd/system/hy2-hop.service \
   /usr/local/bin/hy2-hop-apply.sh /usr/local/bin/hysteria
========================================================
EOF
chmod 600 "$INFO_FILE"
echo ""
cat "$INFO_FILE"
