#!/bin/bash
# Claude 切换器 Linux 版 - 安装器
# 用法: bash install.sh  (部分步骤需要 sudo; FORCE=1 可跳过出口国家校验)
set -u
BASE="$HOME/.claude-switcher"
CLASH_DIR="$HOME/.config/io.github.clash-verge-rev.clash-verge-rev"
[ -d "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev" ] && CLASH_DIR="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"

echo "=================================="
echo "  Claude 账号切换器 · Linux 安装"
echo "=================================="
echo ""

# 国家代码 → 地区格式映射(未收录的国家回退 en_US)
locale_for() {
    case "$1" in
        US) echo en_US ;; JP) echo ja_JP ;; TW) echo zh_TW ;; HK) echo zh_HK ;;
        SG) echo en_SG ;; GB) echo en_GB ;; DE) echo de_DE ;; FR) echo fr_FR ;;
        KR) echo ko_KR ;; AU) echo en_AU ;; CA) echo en_CA ;; *) echo en_US ;;
    esac
}

# ---- 0. 代理客户端探测(Clash Verge → mihomo → sing-box → V2RayA → NekoBox → Hiddify → WireGuard → 手选) ----
if [ -d "$CLASH_DIR" ]; then
    MODE="clash-verge"
elif command -v mihomo >/dev/null 2>&1; then
    MODE="mihomo"
elif command -v sing-box >/dev/null 2>&1; then
    MODE="sing-box"
elif command -v v2raya >/dev/null 2>&1; then
    MODE="v2raya"
elif command -v nekobox >/dev/null 2>&1 || command -v nekoray >/dev/null 2>&1; then
    MODE="nekobox"
elif command -v hiddify >/dev/null 2>&1; then
    MODE="hiddify"
elif command -v wg >/dev/null 2>&1 && systemctl list-units --type=service --state=active 'wg-quick@*' 2>/dev/null | grep -q 'wg-quick@'; then
    MODE="wireguard"
else
    echo "未自动识别到代理客户端,请手动选择(直接回车默认 auto):"
    echo "  1) clash-verge    2) mihomo     3) sing-box"
    echo "  4) v2raya         5) nekobox    6) hiddify"
    echo "  7) wireguard      8) other      9) auto(任一命中即活,默认)"
    read -r -p "请输入序号或名称[9]: " pick
    pick="${pick:-9}"
    case "$pick" in
        1|clash-verge) MODE="clash-verge" ;;
        2|mihomo)      MODE="mihomo" ;;
        3|sing-box)    MODE="sing-box" ;;
        4|v2raya)      MODE="v2raya" ;;
        5|nekobox)     MODE="nekobox" ;;
        6|hiddify)     MODE="hiddify" ;;
        7|wireguard)   MODE="wireguard" ;;
        8|other)       MODE="other" ;;
        9|auto)        MODE="auto" ;;
        *) echo "未识别的选择,退出"; exit 1 ;;
    esac
fi
echo "✓ 代理客户端: $MODE"

# ---- 前置检查 ----
python3 --version >/dev/null 2>&1 || { echo "X 需要 python3,请先安装 (如: sudo apt install python3)"; exit 1; }
systemctl --user --version >/dev/null 2>&1 || { echo "X 需要 systemd(用户服务)"; exit 1; }
command -v dig >/dev/null 2>&1 || echo "提示: 未找到 dig,将使用 nslookup/getent 回退(建议安装 dnsutils/bind-utils)"
echo "✓ 前置检查通过"

# ---- 出口国家校验(出口不能在国内; FORCE=1 可跳过) ----
INFO=$(curl -s --max-time 8 https://ipinfo.io/json 2>/dev/null)
CTRY=$(echo "$INFO" | grep '"country"' | cut -d'"' -f4)
if [ "$CTRY" = "CN" ] && [ -z "${FORCE:-}" ]; then
    echo "X 当前出口在国内(CN),请先开代理(TUN模式)再运行(FORCE=1 可跳过校验)"
    exit 1
fi
if [ -z "$CTRY" ]; then
    echo "X 未能识别出口国家,请确认代理已开启后重试(或用 FORCE=1 跳过)"
    [ -z "${FORCE:-}" ] && exit 1
    CTRY="US"
fi
echo "✓ 出口: $(echo "$INFO" | grep '"ip"' | cut -d'"' -f4) ($CTRY)"

# ---- 地区自适应(按出口IP自动锁定 国家/时区/地区格式 三件套) ----
TZV=$(echo "$INFO" | grep '"timezone"' | cut -d'"' -f4)
[ -z "$TZV" ] && TZV="America/New_York"
LOCALE=$(locale_for "$CTRY")
echo "✓ 地区自适应: 国家=$CTRY 时区=$TZV 地区格式=$LOCALE"

# ---- 自动识别代理组名(仅 Clash Verge;多个 select 组时让用户选,避免静默选错专线) ----
GRP=""
if [ "$MODE" = "clash-verge" ]; then
    GRPS=()
    while IFS= read -r g; do GRPS+=("$g"); done < <(awk '
        /^proxy-groups:/ {f=1; next}
        f && /^[a-zA-Z]/ {f=0}
        f && /- name:/ { n=$0; sub(/.*- name: */, "", n); gsub(/"/, "", n) }
        f && /type: *select/ { print n }
    ' "$CLASH_DIR/clash-verge.yaml" 2>/dev/null)
    if [ "${#GRPS[@]}" -eq 0 ]; then
        read -r -p "未能自动识别代理组名,请打开 Clash Verge 查看后输入: " GRP
        [ -z "$GRP" ] && { echo "未输入,退出"; exit 1; }
    elif [ "${#GRPS[@]}" -eq 1 ]; then
        GRP="${GRPS[0]}"
    else
        echo "检测到多个代理组,请选择用于 Claude 专线的那个:"
        i=1
        for g in "${GRPS[@]}"; do echo "  $i) $g"; i=$((i+1)); done
        read -r -p "请输入序号: " pick
        case "$pick" in ''|*[!0-9]*) echo "输入无效,退出"; exit 1 ;; esac
        if [ "$pick" -lt 1 ] || [ "$pick" -gt "${#GRPS[@]}" ]; then
            echo "序号超范围,退出"; exit 1
        fi
        GRP="${GRPS[$((pick-1))]}"
    fi
    echo "✓ 代理组: $GRP"
fi
[ -z "$GRP" ] && GRP="GLOBAL"

# ---- 安装文件 ----
mkdir -p "$BASE"
DIR="$(cd "$(dirname "$0")" && pwd)"
cp "$DIR/claude-switch.sh" "$BASE/"
cp "$DIR/claude-bodyguard.sh" "$BASE/"
cp "$DIR/stun-probe.py" "$BASE/"
chmod +x "$BASE/claude-switch.sh" "$BASE/claude-bodyguard.sh"
sed -i \
    -e "s|^PROXY_MODE=\".*\"|PROXY_MODE=\"$MODE\"|" \
    -e "s|^PROXY_GROUP=\".*\"|PROXY_GROUP=\"$GRP\"|" \
    -e "s|^COUNTRY_TARGET=\".*\"|COUNTRY_TARGET=\"$CTRY\"|" \
    -e "s|^TZ_TARGET=\".*\"|TZ_TARGET=\"$TZV\"|" \
    -e "s|^LOCALE_TARGET=\".*\"|LOCALE_TARGET=\"$LOCALE\"|" \
    "$BASE/claude-switch.sh"
# 保镖按识别的客户端分派判定(__PROXY_MODE__ 占位符替换)
sed -i "s|__PROXY_MODE__|$MODE|g" "$BASE/claude-bodyguard.sh"
echo "✓ 核心文件已安装到 $BASE"

# ---- 置顶规则(Clash Verge 走核心脚本的智能合并;其他客户端打印清单手动配置) ----
if [ "$MODE" = "clash-verge" ]; then
    "$BASE/claude-switch.sh" write-merge-rules \
        && echo "✓ Claude 域名置顶规则已写入(智能合并,重启 Clash Verge 生效)" \
        || echo "✗ 置顶规则写入失败,可稍后运行 claude-switch fix 重试"
else
    echo ""
    echo "请在你的代理客户端中添加以下 DOMAIN-SUFFIX 置顶规则(优先级高于国内规则集):"
    for d in claude.ai claude.com anthropic.com claudeusercontent.com challenges.cloudflare.com datadoghq.com segment.io stripe.com stripe.network stripecdn.com intercom.io intercomcdn.com intercomassets.com; do
        echo "  - DOMAIN-SUFFIX,$d,$GRP"
    done
fi

# ---- 保镖 systemd 用户服务(免 sudo 常驻) ----
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/claude-bodyguard.service" <<EOF
[Unit]
Description=Claude Bodyguard (kill claude CLI when proxy down)

[Service]
ExecStart=/bin/bash $BASE/claude-bodyguard.sh
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now claude-bodyguard.service >/dev/null 2>&1 \
    && echo "✓ 保镖已注册并启动(systemd 用户服务,登录自启)" \
    || echo "✗ 保镖注册失败,可稍后用 fix 自动补装"

# ---- 时区与 IPv6(需要 sudo) ----
echo ""
echo "接下来需要 sudo 密码: 锁定时区($TZV) + 关闭 IPv6"
sudo timedatectl set-timezone "$TZV" && echo "✓ 时区已锁定"
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null && echo "✓ IPv6 已关闭(运行时)"
echo "net.ipv6.conf.all.disable_ipv6=1" | sudo tee /etc/sysctl.d/90-claude-switcher.conf >/dev/null \
    && echo "✓ IPv6 关闭已持久化(/etc/sysctl.d/90-claude-switcher.conf)"
command -v resolvectl >/dev/null 2>&1 && resolvectl flush-caches 2>/dev/null

# ---- 终端入口 ----
mkdir -p "$HOME/.local/bin"
ln -sf "$BASE/claude-switch.sh" "$HOME/.local/bin/claude-switch" 2>/dev/null
echo ""
echo "=================================="
echo "  ✅ 安装完成!"
echo "  使用: 终端运行 claude-switch menu"
echo "  (或 claude-switch checkdetail / fix / switch A|B)"
echo "=================================="

# ---- 收尾自检 ----
echo ""
echo "---- 收尾自检 (checkdetail) ----"
"$BASE/claude-switch.sh" checkdetail || true
