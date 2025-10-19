#!/usr/bin/env bash
set -euo pipefail

# ================= 配置 =================
MTG_TAR_URL="https://github.com/9seconds/mtg/releases/download/v2.1.7/mtg-2.1.7-linux-amd64.tar.gz"
SPFW_URL="https://github.com/Usagi537233/SPFW/releases/download/0.05/spfw"
INSTALL_DIR="/root/mtg"
SERVICE_FILE="/etc/systemd/system/mtg-whitelist.service"
LOG_DIR="$INSTALL_DIR/logs"
IPSAFE_BASE="https://ipsafev2.537233.xyz"
# ==================================================

# 彩色输出
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
RED="\033[1;31m"
RESET="\033[0m"

info()  { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*"; }

echo -e "${CYAN}================= MTG + SSH 白名单 (SPFW) 一键安装脚本 =================${RESET}"

# 检查必备命令
for c in curl tar gzip systemctl awk sed grep openssl; do
  if ! command -v "$c" >/dev/null 2>&1; then
    error "缺少命令：$c ，请先安装（apt/yum 等）再运行本脚本。"
    exit 1
  fi
done

# 创建目录
mkdir -p "$INSTALL_DIR"
mkdir -p "$LOG_DIR"
cd "$INSTALL_DIR"

# ---------------- 1. 白名单 ----------------
read -e -p "是否已有 path 和 token? (y/n) [n]: " HAVE_TOKEN
HAVE_TOKEN=${HAVE_TOKEN:-n}

if [[ "$HAVE_TOKEN" == "y" || "$HAVE_TOKEN" == "Y" ]]; then
    read -e -p "请输入已有的 path: " PATH_ID
    read -e -p "请输入已有的 token: " TOKEN
    ok "使用用户提供的 path 和 token"
else
    info "创建个人白名单文件夹..."
    RESPONSE=$(curl -fsSL "${IPSAFE_BASE}/mkdir" || true)

    PATH_ID=$(echo "$RESPONSE" | grep -oP 'https?://[^/]+/[a-z0-9]+' | head -n1 | awk -F/ '{print $NF}' || true)
    TOKEN=$(echo "$RESPONSE" | grep -oP '(?<=令牌 )[a-f0-9]+' || true)

    if [ -z "$PATH_ID" ] || [ -z "$TOKEN" ]; then
        warn "自动解析 path/token 失败，显示原始响应供参考："
        echo "$RESPONSE"
        read -e -p "请手动输入 path: " PATH_ID
        read -e -p "请手动输入 token: " TOKEN
    fi

    ok "已创建白名单文件夹"
    echo -e "${CYAN}path:${RESET} $PATH_ID"
    echo -e "${CYAN}token:${RESET} $TOKEN"
    echo -e "${CYAN}$RESPONSE ${RESET}"

    # 将当前 IP 添加到白名单（静默）
    curl -s "${IPSAFE_BASE}/${PATH_ID}/add?token=${TOKEN}" >/dev/null || true
    ok "已将当前 IP 添加到白名单（如需其他 IP，请使用下面的白名单管理链接）"
fi

# ---------------- 2. 用户输入端口与 --hex 域名 ----------------
read -p "请输入 SPFW 对外监听端口（默认 53766）: " EXT_PORT
EXT_PORT=${EXT_PORT:-53766}
if ! [[ "$EXT_PORT" =~ ^[0-9]+$ ]]; then
  error "端口必须为数字"
  exit 1
fi
MTG_PORT=$((EXT_PORT + 1))

read -e -p "请输入 mtg --hex 使用的域名（例如 www.bing.com，默认 www.bing.com）: " HEX_DOMAIN
HEX_DOMAIN=${HEX_DOMAIN:-www.bing.com}

ok "SPFW 外部端口: $EXT_PORT    mtg 本地端口: $MTG_PORT    --hex 域名: $HEX_DOMAIN"

# ---------------- 3. 下载并准备 mtg ----------------
info "下载并解压 mtg..."
TMPDIR=$(mktemp -d)
curl -L -o "$TMPDIR/mtg.tar.gz" "$MTG_TAR_URL"
tar -xzf "$TMPDIR/mtg.tar.gz" -C "$TMPDIR"
# 尝试找到 mtg 可执行
if [ -f "$TMPDIR/mtg" ]; then
  mv "$TMPDIR/mtg" "$INSTALL_DIR/mtg"
else
  found=$(find "$TMPDIR" -type f -name mtg | head -n1 || true)
  if [ -n "$found" ]; then
    mv "$found" "$INSTALL_DIR/mtg"
  elif [ -f "$TMPDIR/mtg-2.1.7-linux-amd64/mtg" ]; then
    mv "$TMPDIR/mtg-2.1.7-linux-amd64/mtg" "$INSTALL_DIR/mtg"
  else
    error "未能找到 mtg 可执行文件，解压路径：$TMPDIR 内容："
    ls -al "$TMPDIR"
    exit 1
  fi
fi
chmod +x "$INSTALL_DIR/mtg"
ok "mtg 已就绪：$INSTALL_DIR/mtg"

# ---------------- 4. 下载 spfw ----------------
info "下载 spfw..."
curl -L -o "$INSTALL_DIR/spfw" "$SPFW_URL"
chmod +x "$INSTALL_DIR/spfw"
ok "spfw 已就绪：$INSTALL_DIR/spfw"

# ---------------- 5. 生成 secret（支持自定义 --hex 域名） ----------------
info "生成 mtg secret（使用 --hex $HEX_DOMAIN）..."
SECRET=$("$INSTALL_DIR/mtg" generate-secret --hex "$HEX_DOMAIN" 2>/dev/null || true)
if [ -z "$SECRET" ]; then
    warn "mtg 自带生成失败，改用随机作为后备 secret"
    SECRET=$(openssl rand -hex 16)
fi
ok "secret: $SECRET"

# ---------------- 6. 写启动脚本 start.sh（保留原脚本风格） ----------------
cat > "$INSTALL_DIR/start.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
MTG_BIN="\$INSTALL_DIR/mtg"
SPFW_BIN="\$INSTALL_DIR/spfw"
LOG_DIR="\$INSTALL_DIR/logs"
MTG_PORT="$MTG_PORT"
EXT_PORT="$EXT_PORT"
SECRET="$SECRET"
PATH_ID="$PATH_ID"
TOKEN="$TOKEN"
IPSAFE_BASE="$IPSAFE_BASE"

mkdir -p "\$LOG_DIR"

MTG_LOG="\$LOG_DIR/mtg.log"
SPFW_LOG="\$LOG_DIR/spfw.log"

pids=""
cleanup() {
  echo -e "[start.sh] 收到停止信号，准备停止子进程..."
  for pid in \$pids; do
    if kill -0 "\$pid" >/dev/null 2>&1; then
      kill "\$pid" || true
    fi
  done
  sleep 1
  exit 0
}
trap cleanup SIGTERM SIGINT

echo -e "[start.sh] 启动 mtg：\$MTG_BIN simple-run 127.0.0.1:\$MTG_PORT \"\$SECRET\" --doh-ip=1.1.1.1 -d"
"\$MTG_BIN" simple-run 127.0.0.1:"\$MTG_PORT" "\$SECRET" --doh-ip=1.1.1.1 -d >>"\$MTG_LOG" 2>&1 &
pid_mtg=\$!
pids="\$pids \$pid_mtg"

# 稍作等待
sleep 1

SPFW_URL="\$IPSAFE_BASE/\$PATH_ID/iplist?token=\$TOKEN"
echo -e "[start.sh] 启动 spfw：\$SPFW_BIN -L tcp://:\$EXT_PORT/127.0.0.1:\$MTG_PORT -url \$SPFW_URL -t 5"
"\$SPFW_BIN" -L tcp://:"\$EXT_PORT"/127.0.0.1:"\$MTG_PORT" -url "\$SPFW_URL" -t 5 >>"\$SPFW_LOG" 2>&1 &
pid_spfw=\$!
pids="\$pids \$pid_spfw"

# 等待子进程（保持前台）
wait
EOF

chmod +x "$INSTALL_DIR/start.sh"
ok "启动脚本已生成：$INSTALL_DIR/start.sh"

# ---------------- 7. 生成 systemd 服务（单服务管理 mtg + spfw） ----------------
info "生成 systemd 服务文件：$SERVICE_FILE"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=mtg (MTProto) + SPFW (whitelist forwarder)
After=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/start.sh
ExecStop=/bin/kill -TERM \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

ok "systemd 服务文件已生成：$SERVICE_FILE"

# ---------------- 8. 启动服务并启用开机自启 ----------------
info "重新加载 systemd 配置..."
systemctl daemon-reload

info "正在启动并设置开机自启 mtg-whitelist.service..."
systemctl enable --now mtg-whitelist.service

sleep 1
systemctl status mtg-whitelist.service --no-pager || true

# ---------------- 9. 输出并保存一键链接与白名单说明（保留原脚本格式） ----------------
ThisIP=$(curl -fsSL ip.sb -4 || curl -fsSL icanhazip.com -4 || true)
if [ -z "$ThisIP" ]; then
  warn "无法获取公网 IPv4 地址，请手动检查服务器 IP"
  ThisIP="YOUR_SERVER_IP"
fi

TG_LINK_HTTPS="https://t.me/proxy?server=${ThisIP}&port=${EXT_PORT}&secret=${SECRET}"
TG_LINK_TG="tg://proxy?server=${ThisIP}&port=${EXT_PORT}&secret=${SECRET}"

echo -e "${YELLOW}正在重启 mtg 服务...${RESET}"
# (systemd 已经 restart 过，以上仅保留原提示风格)
echo -e "${GREEN}mtg 已启动并设置为开机自启${RESET}"
echo

echo -e "${GREEN}一键链接: $TG_LINK_HTTPS ${RESET}"
echo -e "${GREEN}TG一键链接: $TG_LINK_TG ${RESET}"

# 写入 /root/mtg/link.txt（保留原脚本输出样式）
cat > "$INSTALL_DIR/link.txt" <<EOF
一键链接: $TG_LINK_HTTPS
TG一键链接: $TG_LINK_TG

白名单管理：
添加当前 IP: $IPSAFE_BASE/$PATH_ID/add?token=$TOKEN
手动添加 IP: $IPSAFE_BASE/$PATH_ID/add?ip=<目标IP>&token=$TOKEN

说明：
- mtg 监听：127.0.0.1:$MTG_PORT
- SPFW 对外端口：$EXT_PORT（仅允许白名单 IP 访问）
- secret (--hex $HEX_DOMAIN)：$SECRET

日志：
$INSTALL_DIR/logs/mtg.log
$INSTALL_DIR/logs/spfw.log

链接保存在 /root/mtg/link.txt
EOF

ok "TG 一键链接与白名单管理链接已保存到 $INSTALL_DIR/link.txt"

# --------------- 10. 最后使用说明（保留 sshwhitelist 原脚本结尾风格） ---------------
echo -e "\n${CYAN}================= 使用说明 =================${RESET}"
echo -e "如需添加其他 IP 到白名单，请在其他 IP 环境下访问网址："
echo -e "  ${YELLOW}$IPSAFE_BASE/$PATH_ID/add?token=$TOKEN${RESET}"
echo -e "或者直接使用如下方式添加指定 IP："
echo -e "  ${YELLOW}$IPSAFE_BASE/$PATH_ID/add?ip=<目标IP>&token=$TOKEN${RESET}"
echo -e "${CYAN}===========================================${RESET}\n"

ok "安装完成。若需查看服务状态： systemctl status mtg-whitelist.service"
ok "若需查看日志： tail -n 200 $INSTALL_DIR/logs/mtg.log"
ok "TG 链接和白名单链接已写入： $INSTALL_DIR/link.txt"

exit 0
