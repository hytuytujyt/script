#!/bin/sh
# =====================================================================
#  install_reality.sh (单文件自举版 v2)
#  兼容 Alpine / Debian / Ubuntu / Fedora / CentOS / openSUSE 等
#
#  支持两种执行方式:
#    1) 已有本地文件:  sh install_reality.sh
#    2) 管道直接喂:    wget -qO- <URL> | ... sh
#                      curl -fsSL <URL> | ... sh
#                      busybox wget -qO- <URL> | ... sh   (Alpine等精简系统兜底)
#  无论哪种,脚本都会自动补齐 bash/curl,再自动用 bash 自举执行正文。
# =====================================================================

SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh}"

# ---------- 简易打印工具(供引导段与正文共用) ----------
# 用命令替代 echo 传递多行,统一错误输出到 stderr
_info() { printf '%s\n' "[*] $*"; }
_ok()   { printf '%s\n' "[✓] $*"; }
_err()  { printf '%s\n' "[!] $*" >&2; }
_cmd()  { command -v "$1" >/dev/null 2>&1; }

if [ -z "${BASH_VERSION:-}" ]; then
  # ---------------------------------------------------------------
  #  引导段 (POSIX sh 兼容,可使 busybox ash 运行)
  # ---------------------------------------------------------------

  _need_install=""
  _cmd bash || _need_install="$_need_install bash"
  _cmd curl || _need_install="$_need_install curl"

  if [ -n "$_need_install" ]; then
    _err "检测到缺少依赖:$_need_install"
    _info "开始自动安装缺少的依赖 ..."
    if _cmd apk; then                                 # Alpine
      _info "使用 apk 安装"
      apk update && apk add --no-cache bash curl
    elif _cmd apt-get; then                           # Debian / Ubuntu
      export DEBIAN_FRONTEND=noninteractive
      _info "使用 apt-get 安装"
      apt-get update
      apt-get install -y bash curl
    elif _cmd dnf; then                               # Fedora / RHEL9+ / Rocky / Alma
      _info "使用 dnf 安装"
      dnf makecache
      dnf install -y bash curl
    elif _cmd yum; then                               # CentOS7 / RHEL7
      _info "使用 yum 安装"
      yum install -y bash curl
    elif _cmd zypper; then                            # openSUSE / SLES
      _info "使用 zypper 安装"
      zypper --non-interactive install bash curl
    elif _cmd pacman; then                            # Arch
      _info "使用 pacman 安装"
      pacman -Sy --noconfirm bash curl
    else
      _err "未识别的包管理器。"
      _err "请手动安装 bash 和 curl,然后重新执行本脚本。"
      _err "   - Alpine:  apk add bash curl"
      _err "   - Debian/Ubuntu:  apt-get install -y bash curl"
      _err "   - Fedora:  dnf install -y bash curl"
      _err "   - CentOS7: yum install -y bash curl"
      exit 1
    fi
    # 复查
    _cmd bash || { _err "bash 仍未安装成功,请手动排查后重试"; exit 1; }
    _cmd curl || { _err "curl 仍未安装成功,请手动排查后重试"; exit 1; }
    _ok "依赖安装完成"
  else
    _ok "bash / curl 均已就绪"
  fi

  # 用 bash 重新执行本脚本(正文是 bash 语法)
  if [ -n "$0" ] && [ -f "$0" ]; then
    exec bash "$0" "$@"
  else
    _info "管道模式下自举:下载脚本交 bash 执行 ..."
    _tmp_self="/tmp/install_reality_bootstrap.sh"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$SCRIPT_URL" -o "$_tmp_self" || { _err "拉取脚本失败(使用 curl): $SCRIPT_URL"; exit 1; }
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$_tmp_self" "$SCRIPT_URL" || { _err "拉取脚本失败(使用 wget): $SCRIPT_URL"; exit 1; }
    elif command -v busybox >/dev/null 2>&1; then
      busybox wget -qO "$_tmp_self" "$SCRIPT_URL" || { _err "拉取脚本失败(使用 busybox wget): $SCRIPT_URL"; exit 1; }
    else
      _err "需要 curl / wget / busybox 之一才能自举拉取脚本。"
      _err "请先安装其中之一,或将脚本下载到本地后执行: sh install_reality.sh"
      exit 1
    fi
    exec bash "$_tmp_self" "$@"
  fi
fi

# =====================================================================
#  正文段 (此时已在 bash 下运行)
# =====================================================================
set -euo pipefail

_info2() { printf '%s\n' "[*] $*"; }
_ok2()   { printf '%s\n' "[✓] $*"; }
_err2()  { printf '%s\n' "[!] $*" >&2; }

### 可通过环境变量覆盖的配置 ###
LISTEN_PORT="${LISTEN_PORT:-0}"
SERVER_LISTEN_PORT=443                                        # sing-box 实际监听端口,恒定443
REALITY_DEST="${REALITY_DEST:-addons.mozilla.org:443}"        # 伪装握手目标
REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-addons.mozilla.org}"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"

if [ "$LISTEN_PORT" -eq 0 ]; then
  OUTPUT_PORT=$SERVER_LISTEN_PORT
else
  OUTPUT_PORT=$LISTEN_PORT
fi

### 1. 安装 sing-box(幂等,已装则跳过) ###
install_singbox() {
  if command -v sing-box >/dev/null 2>&1; then
    _ok2 "sing-box 已安装,跳过"
    return
  fi
  _info2 "安装 sing-box ..."
  if command -v apk >/dev/null 2>&1; then
    _info2 "Alpine 检测到,使用 apk 绝对路径安装 ..."
    local arch download_version pkg
    arch=$(apk --print-arch)
    if ! download_version=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest \
        | sed -n 's/.*"tag_name": "v\([^"]*\)".*/\1/p' | head -n1); then
      _err2 "获取 sing-box 最新版本失败(网络或证书问题?)"
      _err2 "请确认: curl 可用、网络可达、ca-certificates 已安装"
      exit 1
    fi
    if [ -z "$download_version" ]; then
      _err2 "未能从 GitHub API 解析出 sing-box 版本号"
      exit 1
    fi
    pkg="/tmp/sing-box_${download_version}_linux_${arch}.apk"
    pkg_url="https://github.com/SagerNet/sing-box/releases/download/v${download_version}/sing-box_${download_version}_linux_${arch}.apk"
    _info2 "下载 $pkg_url"
    if ! curl -fsSL -o "$pkg" "$pkg_url"; then
      _err2 "下载 sing-box 安装包失败: $pkg_url"
      _err2 "请检查网络,或在配置代理后重试"
      exit 1
    fi
    apk add --allow-untrusted "$pkg"
    rm -f "$pkg"
  else
    if ! bash <(curl -fsSL https://sing-box.app/install.sh); then
      _err2 "sing-box 官方安装脚本执行失败"
      _err2 "请检查网络,或到 https://github.com/SagerNet/sing-box/releases 手动安装"
      exit 1
    fi
  fi
}

### 2. 生成密钥 / UUID / short_id ###
generate_credentials() {
  _info2 "生成 Reality 密钥对与身份信息 ..."
  local key_output
  key_output=$(sing-box generate reality-keypair)
  PRIVATE_KEY=$(echo "$key_output" | awk '/PrivateKey/{print $2}')
  PUBLIC_KEY=$(echo "$key_output" | awk '/PublicKey/{print $2}')
  UUID=$(sing-box generate uuid)
  SHORT_ID=$(sing-box generate rand 8 --hex)
}

### 3. 写入服务端配置文件(监听端口恒定443) ###
write_config() {
  mkdir -p "$CONFIG_DIR"
  local dest_host="${REALITY_DEST%:*}"
  local dest_port="${REALITY_DEST##*:}"
  cat > "$CONFIG_FILE" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": ${SERVER_LISTEN_PORT},
      "users": [
        { "uuid": "${UUID}", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SERVER_NAME}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${dest_host}", "server_port": ${dest_port} },
          "private_key": "${PRIVATE_KEY}",
          "short_id": ["${SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [ { "type": "direct" } ]
}
EOF
  _ok2 "配置文件已写入 $CONFIG_FILE"
}

### 4. 检查并放行防火墙 ###
check_and_open_firewall() {
  local port=$SERVER_LISTEN_PORT
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
    if ! ufw status 2>/dev/null | grep -q "$port"; then
      ufw allow "$port" >/dev/null 2>&1
      _ok2 "ufw 已自动放行端口 $port"
    else
      _ok2 "ufw 端口 $port 已放行"
    fi
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q "running"; then
    if ! firewall-cmd --list-ports 2>/dev/null | grep -q "$port/tcp"; then
      firewall-cmd --add-port="$port/tcp" --permanent >/dev/null 2>&1
      firewall-cmd --reload >/dev/null 2>&1
      _ok2 "firewalld 已自动放行端口 $port"
    else
      _ok2 "firewalld 端口 $port 已放行"
    fi
  fi
  if command -v iptables >/dev/null 2>&1; then
    if iptables -L INPUT -n 2>/dev/null | grep -q "DROP\|REJECT"; then
      _err2 "iptables 有拒绝规则,可能拦截端口 $port"
      _err2 "请手动检查: iptables -L INPUT -n | grep DROP"
    fi
  fi
  _info2 "如果连不上,请检查云厂商控制面板的安全组/防火墙是否放行了端口 $port"
}

### 5. 启动服务(自动识别 systemd / openrc) ###
start_service() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable sing-box && systemctl restart sing-box
    _ok2 "已通过 systemd 启动 sing-box"
  elif command -v rc-service >/dev/null 2>&1; then
    rc-update add sing-box default && rc-service sing-box restart
    _ok2 "已通过 openrc 启动 sing-box"
  else
    _err2 "未识别到 systemd/openrc,请手动启动 sing-box"
  fi
}

### 6. 输出 vless 链接 + 客户端 config.json,并存档一份 ###
print_result() {
  local ip="$RESOLVED_IP"
  local link="vless://${UUID}@${ip}:${OUTPUT_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#reality-$(hostname)"

  {
    echo ""
    echo "================ VLESS 链接 ================"
    echo "$link"

    echo ""
    echo "============ 客户端 config.json ============"
    cat <<EOF
    {
      "type": "vless",
      "tag": "reality-out",
      "server": "${ip}",
      "server_port": ${OUTPUT_PORT},
      "uuid": "${UUID}",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SERVER_NAME}",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": {
          "enabled": true,
          "public_key": "${PUBLIC_KEY}",
          "short_id": "${SHORT_ID}"
        }
      }
    }
EOF
    echo "=============================================="
  } | tee "${CONFIG_DIR}/node_output.txt"
}

### 7. 写入 shownode 快捷指令(同时兼容 bash 和 Alpine 的 ash) ###
setup_alias() {
  local alias_line="alias shownode='cat ${CONFIG_DIR}/node_output.txt'"
  for rc in ~/.bashrc ~/.profile; do
    touch "$rc"
    if ! grep -qxF "$alias_line" "$rc" 2>/dev/null; then
      echo "$alias_line" >> "$rc"
    fi
  done
}

install_singbox
generate_credentials
RESOLVED_IP="$SERVER_IP"
write_config
check_and_open_firewall
start_service
print_result
setup_alias
echo ""
_ok2 "已写入 shownode 快捷指令,重新连一次SSH(或执行 source ~/.bashrc)后即可用 shownode 查看节点信息"
