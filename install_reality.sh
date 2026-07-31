#!/bin/sh
# =====================================================================
#  install_reality.sh (单文件自举版)
#  兼容 Alpine / Ubuntu / Debian / Fedora / CentOS / openSUSE 等
#
#  支持两种执行方式:
#    1) 已有本地文件:  sh install_reality.sh
#    2) 管道直接喂:    wget -qO- <URL> | ... sh
#                      curl -fsSL <URL> | ... sh
#  无论哪种,脚本都会自动补齐 bash/curl,再自动用 bash 自举执行正文。
# =====================================================================

# 自举时(管道模式下)重新拉取自身所用的地址;可用环境变量覆盖
SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh}"
#
#  用法:
#    把本文件弄到服务器上(任意方式),然后只需执行:
#        sh install_reality.sh
#    脚本会先自动补齐 bash/curl 依赖,再自动用 bash 重新执行自己,
#    全程你只跑这一条命令,无需手动装依赖。
#
#  参数(环境变量)照旧:
#        LISTEN_PORT=0 SERVER_IP=1.2.3.4 sh install_reality.sh
#
#  首次以 sh 运行时执行"引导段",装好依赖后 exec bash 自举;
#  第二次以 bash 运行时(BASH_VERSION 已存在)跳过引导段,直接进正文。
# =====================================================================

if [ -z "${BASH_VERSION:-}" ]; then
  # ---------------------------------------------------------------
  #  引导段 (POSIX sh 兼容,可使 busybox ash 运行)
  # ---------------------------------------------------------------
  _cmd() { command -v "$1" >/dev/null 2>&1; }

  # 缺则装:  bash(跑正文需要)  curl(下载 sing-box 需要)
  _need_install=""
  _cmd bash || _need_install="$_need_install bash"
  _cmd curl  || _need_install="$_need_install curl"

  if [ -n "$_need_install" ]; then
    echo "[*] 检测到缺少依赖:$_need_install ,开始自动安装 ..."
    if _cmd apk; then                       # Alpine
      apk update && apk add --no-cache bash curl
    elif _cmd apt-get; then                 # Debian / Ubuntu
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y bash curl
    elif _cmd dnf; then                     # Fedora / RHEL9+ / Rocky / Alma
      dnf makecache
      dnf install -y bash curl
    elif _cmd yum; then                     # CentOS7 / RHEL7
      yum install -y bash curl
    elif _cmd zypper; then                  # openSUSE / SLES
      zypper --non-interactive install bash curl
    elif _cmd pacman; then                  # Arch
      pacman -Sy --noconfirm bash curl
    else
      echo "[!] 未识别的包管理器,请手动安装 bash 和 curl" >&2
      exit 1
    fi

    # 复查
    if ! _cmd bash || ! _cmd curl; then
      echo "[!] 依赖安装未成功,请手动检查" >&2
      exit 1
    fi
    echo "[✓] 依赖安装完成"
  else
    echo "[✓] bash / curl 均已就绪"
  fi

  # 用 bash 重新执行本脚本(正文是 bash 语法)
  # 优先用当前脚本文件;若是在管道里执行($0 不是有效文件),则重新拉取自身。
  if [ -n "$0" ] && [ -f "$0" ]; then
    # 本地文件模式: 直接 exec bash 重跑本文件
    exec bash "$0" "$@"
  else
    # 管道模式: 用刚装好的 curl(或 wget)下载脚本到临时文件,再 exec bash 接管
    # 注意: 必须用"单独一条 exec bash 文件"(而非 exec cmd|bash 管道),
    #       因为在管道左端的 exec 只替换 subshell、不会替换主 sh,
    #       主 sh 之后会继续读 stdin 剩下的正文重复执行。
    echo "[*] 管道模式下自举:下载脚本交 bash 执行 ..."
    _tmp_self="/tmp/install_reality_bootstrap.sh"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$SCRIPT_URL" -o "$_tmp_self" || exit 1
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$_tmp_self" "$SCRIPT_URL" || exit 1
    else
      echo "[!] 需要 curl 或 wget 来自举" >&2
      exit 1
    fi
    exec bash "$_tmp_self" "$@"
  fi
fi

# =====================================================================
#  正文段 (此时已在 bash 下运行)
# =====================================================================
set -euo pipefail

### 可通过环境变量覆盖的配置 ###
# LISTEN_PORT=0        表示非NAT机器,内网/外部都用443
# LISTEN_PORT=xxxxx    表示NAT机器,NAT映射到内部443端口的外部端口号是xxxxx
LISTEN_PORT="${LISTEN_PORT:-0}"
SERVER_LISTEN_PORT=443                                        # sing-box 实际监听端口,恒定443
REALITY_DEST="${REALITY_DEST:-addons.mozilla.org:443}"        # 伪装握手目标
REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-addons.mozilla.org}"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"

### 根据 LISTEN_PORT 判断输出端口 ###
if [ "$LISTEN_PORT" -eq 0 ]; then
  OUTPUT_PORT=$SERVER_LISTEN_PORT
else
  OUTPUT_PORT=$LISTEN_PORT
fi

### 1. 安装 sing-box(幂等,已装则跳过)###
install_singbox() {
  if command -v sing-box >/dev/null 2>&1; then
    echo "[*] sing-box 已安装,跳过"
    return
  fi
  echo "[*] 安装 sing-box ..."
  # Alpine 用 apk:官方脚本的相对路径 + sudo 在 apk 上会解析失败(IO ERROR),
  # 这里手动下载到绝对路径、直接用绝对路径安装,绕开该坑。
  if command -v apk >/dev/null 2>&1; then
    echo "  [*] Alpine 检测到,使用 apk 绝对路径安装 ..."
    local arch download_version pkg
    arch=$(apk --print-arch)
    download_version=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest \
      | sed -n 's/.*"tag_name": "v\([^"]*\)".*/\1/p' | head -n1)
    if [ -z "$download_version" ]; then
      echo "[!] 获取 sing-box 最新版本失败" >&2
      exit 1
    fi
    pkg="/tmp/sing-box_${download_version}_linux_${arch}.apk"
    pkg_url="https://github.com/SagerNet/sing-box/releases/download/v${download_version}/sing-box_${download_version}_linux_${arch}.apk"
    echo "  [*] 下载 $pkg_url"
    curl -fsSL -o "$pkg" "$pkg_url"
    apk add --allow-untrusted "$pkg"
    rm -f "$pkg"
  else
    bash <(curl -fsSL https://sing-box.app/install.sh)
  fi
}

### 2. 生成密钥 / UUID / short_id ###
generate_credentials() {
  echo "[*] 生成 Reality 密钥对与身份信息 ..."
  local key_output
  key_output=$(sing-box generate reality-keypair)
  PRIVATE_KEY=$(echo "$key_output" | awk '/PrivateKey/{print $2}')
  PUBLIC_KEY=$(echo "$key_output" | awk '/PublicKey/{print $2}')
  UUID=$(sing-box generate uuid)
  SHORT_ID=$(sing-box generate rand 8 --hex)
}

### 3. 写入服务端配置文件(监听端口恒定443)###
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
}

### 4. 检查并放行防火墙 ###
check_and_open_firewall() {
  local port=$SERVER_LISTEN_PORT
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
    if ! ufw status 2>/dev/null | grep -q "$port"; then
      ufw allow "$port" >/dev/null 2>&1
      echo "[✓] ufw 已自动放行端口 $port"
    else
      echo "[✓] ufw 端口 $port 已放行"
    fi
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q "running"; then
    if ! firewall-cmd --list-ports 2>/dev/null | grep -q "$port/tcp"; then
      firewall-cmd --add-port="$port/tcp" --permanent >/dev/null 2>&1
      firewall-cmd --reload >/dev/null 2>&1
      echo "[✓] firewalld 已自动放行端口 $port"
    else
      echo "[✓] firewalld 端口 $port 已放行"
    fi
  fi
  if command -v iptables >/dev/null 2>&1; then
    if iptables -L INPUT -n 2>/dev/null | grep -q "DROP\|REJECT"; then
      echo "[!] iptables 有拒绝规则,可能拦截端口 $port"
      echo "    请手动检查: iptables -L INPUT -n | grep DROP"
    fi
  fi
  echo "[*] 如果连不上,请检查云厂商控制面板的安全组/防火墙是否放行了端口 $port"
}

### 5. 启动服务(自动识别 systemd / openrc) ###
start_service() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable sing-box && systemctl restart sing-box
  elif command -v rc-service >/dev/null 2>&1; then
    rc-update add sing-box default && rc-service sing-box restart
  else
    echo "[!] 未识别到 systemd/openrc,请手动启动 sing-box"
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
echo "[*] 已写入 shownode 快捷指令,重新连一次SSH(或执行 source ~/.bashrc)后即可用 shownode 查看节点信息"