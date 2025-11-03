#!/usr/bin/env bash
set -euo pipefail

# ================= 配置 =================
MTG_TAR_URL="https://github.com/9seconds/mtg/releases/download/v2.1.7/mtg-2.1.7-linux-amd64.tar.gz"
SPFW_URL="https://github.com/Usagi537233/SPFW/releases/download/v0.0.9/spfw"
INSTALL_DIR="/root/mtg"
SERVICE_FILE="/etc/systemd/system/mtg-whitelist.service"
LOG_DIR="$INSTALL_DIR/logs"
# ========================================

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

# 选择站点
echo -e "\n请选择要使用的站点："
echo "1) 公益站（https://ipsafev2.537233.xyz）"
echo "2) 专业站（https://ipm.537233.xyz）"
read -p "输入 1 或 2 [1]: " SITE_CHOICE
SITE_CHOICE=${SITE_CHOICE:-1}

if [ "$SITE_CHOICE" == "2" ]; then
    IPSAFE_BASE="https://ipm.537233.xyz"
    IS_PROFESSIONAL=true
    ok "选择：专业站 ($IPSAFE_BASE)"
else
    IPSAFE_BASE="https://ipsafev2.537233.xyz"
    IS_PROFESSIONAL=false
    ok "选择：公益站 ($IPSAFE_BASE)"
fi

# 创建目录
mkdir -p "$INSTALL_DIR"
mkdir -p "$LOG_DIR"
cd "$INSTALL_DIR"

# ---------------- 1. 白名单 ----------------
read -e -p "是否已有 path 和 token? (y/n) [n]: " HAVE_TOKEN
HAVE_TOKEN=${HAVE_TOKEN:-n}

if [[ "$HAVE_TOKEN" =~ ^[Yy]$ ]]; then
    read -e -p "请输入已有的 path: " PATH_ID
    read -e -p "请输入已有的 token: " TOKEN
    ok "使用用户提供的 path 和 token"
else
    # 自定义 token 选项
    read -e -p "是否自定义 token? (y/n) [n]: " TOKEN_CHOICE
    TOKEN_CHOICE=${TOKEN_CHOICE:-n}
    TOKEN_INPUT=""
    TOKEN_PARAM=""
    if [[ "$TOKEN_CHOICE" =~ ^[Yy]$ ]]; then
        read -e -p "请输入自定义 token: " TOKEN_INPUT
    fi

    if [ "$IS_PROFESSIONAL" = true ]; then
        # 专业站必须 dir + key
        while true; do
            read -e -p "请输入要创建的自定义 dir 名称（例如 myserver123）: " DIR
            while true; do
                read -e -p "请输入你的授权 key: " KEY
                info "正在验证 key 并创建个人白名单文件夹..."
                TOKEN_PARAM=""
                [[ -n "$TOKEN_INPUT" ]] && TOKEN_PARAM="&token=${TOKEN_INPUT}"
                RESPONSE=$(curl -fsSL "${IPSAFE_BASE}/mkdir?key=${KEY}&dir=${DIR}${TOKEN_PARAM}" || true)

                if echo "$RESPONSE" | grep -q "錯誤：key 不正確" || echo "$RESPONSE" | grep -q "error: invalid key"; then
                    error "key 不正确，无法创建目录。"
                    read -e -p "是否重新输入 key/dir？(y/n): " RETRY
                    [[ "$RETRY" =~ ^[Nn]$ ]] && exit 1
                    break
                fi

                if echo "$RESPONSE" | grep -q "錯誤：目錄已存在" || echo "$RESPONSE" | grep -q "error: directory already exists"; then
                    error "目录已存在，请使用其他名称。"
                    read -e -p "是否重新输入 dir？(y/n): " RETRY
                    [[ "$RETRY" =~ ^[Nn]$ ]] && exit 1
                    break
                fi

                # 自动解析 path 和 token（兼容中文/英文）
                PATH_ID=$(echo "$RESPONSE" | grep -oP 'https?://[^/]+/[a-zA-Z0-9_-]+' | head -n1 | awk -F/ '{print $NF}')
                if [[ -n "$TOKEN_INPUT" ]]; then
                    TOKEN="$TOKEN_INPUT"
                else
                    TOKEN=$(echo "$RESPONSE" | grep -oP '(?<=token )[a-f0-9]{16,32}' || true)
                fi

                if [ -z "$PATH_ID" ] || [ -z "$TOKEN" ]; then
                    warn "解析 path/token 失败，响应内容如下："
                    echo "$RESPONSE"
                    read -e -p "是否重新输入 key/dir？(y/n): " RETRY
                    [[ "$RETRY" =~ ^[Nn]$ ]] && exit 1
                    break
                fi

                ok "已成功创建白名单文件夹"
                break 2
            done
        done
    else
        # 公益站：自动随机 dir
        info "使用公益站，自动创建随机目录..."
        TOKEN_PARAM=""
        [[ -n "$TOKEN_INPUT" ]] && TOKEN_PARAM="?token=${TOKEN_INPUT}"
        RESPONSE=$(curl -fsSL "${IPSAFE_BASE}/mkdir${TOKEN_PARAM}" || true)
        echo "$RESPONSE"
        # 自动解析 path 和 token（兼容中文/英文）
        PATH_ID=$(echo "$RESPONSE" | grep -oP 'https?://[^/]+/[a-zA-Z0-9_-]+' | head -n1 | awk -F/ '{print $NF}')
        if [[ -n "$TOKEN_INPUT" ]]; then
            TOKEN="$TOKEN_INPUT"
        else
            TOKEN=$(echo "$RESPONSE" | grep -oP '(?<=令牌 |token )[a-f0-9]{16,32}' || true)
        fi
    fi
fi

# 如果 path/token 为空则手动输入
if [ -z "$PATH_ID" ] || [ -z "$TOKEN" ]; then
    warn "自动解析 path/token 失败，显示原始响应供参考："
    echo "$RESPONSE"
    read -e -p "请手动输入 path: " PATH_ID
    read -e -p "请手动输入 token: " TOKEN
fi

ok "已创建白名单文件夹"
echo -e "${CYAN}path:${RESET} $PATH_ID"
echo -e "${CYAN}token:${RESET} $TOKEN"

# 将当前 IP 添加到白名单（静默）
curl -s "${IPSAFE_BASE}/${PATH_ID}/add?token=${TOKEN}" >/dev/null || true
ok "已将当前 IP 添加到白名单（如需其他 IP，请使用白名单管理链接）"

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
if [ -f "$TMPDIR/mtg" ]; then
  mv "$TMPDIR/mtg" "$INSTALL_DIR/mtg"
else
  found=$(find "$TMPDIR" -type f -name mtg | head -n1 || true)
  if [ -n "$found" ]; then
    mv "$found" "$INSTALL_DIR/mtg"
  else
    error "未能找到 mtg 可执行文件"
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

# ---------------- 5. 生成 secret ----------------
info "生成 mtg secret..."
SECRET=$("$INSTALL_DIR/mtg" generate-secret --hex "$HEX_DOMAIN" 2>/dev/null || true)
if [ -z "$SECRET" ]; then
    warn "mtg 自带生成失败，改用随机作为后备 secret"
    SECRET=$(openssl rand -hex 16)
fi
ok "secret: $SECRET"

# ---------------- 6. 写启动脚本 start.sh ----------------
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

echo -e "[start.sh] 启动 mtg..."
"\$MTG_BIN" simple-run 127.0.0.1:"\$MTG_PORT" "\$SECRET" --doh-ip=1.1.1.1 -d >>"\$MTG_LOG" 2>&1 &
pid_mtg=\$!
pids="\$pids \$pid_mtg"

sleep 1

SPFW_URL="\$IPSAFE_BASE/\$PATH_ID/iplist?token=\$TOKEN"
echo -e "[start.sh] 启动 spfw..."
"\$SPFW_BIN" -L tcp://:"\$EXT_PORT"/127.0.0.1:"\$MTG_PORT" -url "\$SPFW_URL" -t 5 >>"\$SPFW_LOG" 2>&1 &
pid_spfw=\$!
pids="\$pids \$pid_spfw"

wait
EOF
chmod +x "$INSTALL_DIR/start.sh"
ok "启动脚本已生成：$INSTALL_DIR/start.sh"

# ---------------- 7. systemd ----------------
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=mtg + spfw whitelist
After=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/start.sh
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mtg-whitelist.service
ok "systemd 服务已创建并启动"

# ---------------- 8. 输出结果 ----------------
ThisIP=$(curl -fsSL ip.sb -4 || curl -fsSL icanhazip.com -4 || true)
TG_LINK_HTTPS="https://t.me/proxy?server=${ThisIP}&port=${EXT_PORT}&secret=${SECRET}"
TG_LINK_TG="tg://proxy?server=${ThisIP}&port=${EXT_PORT}&secret=${SECRET}"

cat > "$INSTALL_DIR/link.txt" <<EOF
一键链接: $TG_LINK_HTTPS
TG一键链接: $TG_LINK_TG

白名单管理：
添加当前 IP: $IPSAFE_BASE/$PATH_ID/add?token=$TOKEN
手动添加 IP: $IPSAFE_BASE/$PATH_ID/add?ip=<目标IP>&token=$TOKEN

说明：
- mtg 监听：127.0.0.1:$MTG_PORT
- SPFW 对外端口：$EXT_PORT
- secret (--hex $HEX_DOMAIN)：$SECRET

日志：
$INSTALL_DIR/logs/mtg.log
$INSTALL_DIR/logs/spfw.log
EOF

ok "安装完成，信息保存于 $INSTALL_DIR/link.txt"
