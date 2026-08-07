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
_warn2() { printf '%s\n' "[!] $*" >&2; }

### 可通过环境变量覆盖的配置 ###
LISTEN_PORT="${LISTEN_PORT:-0}"
SERVER_LISTEN_PORT=443                                        # sing-box 实际监听端口,恒定443
REALITY_DEST="${REALITY_DEST:-addons.mozilla.org:443}"        # 伪装握手目标
REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-addons.mozilla.org}"
NODE_NAME="${NODE_NAME:-reality-$(hostname)}"        # 节点名(YAML/链接里显示,可用 NODE_NAME 环境变量覆盖)
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"

# 必需参数校验 (SERVER_IP 必须提供,否则 set -u 会报难懂的 unbound variable)
if [ -z "${SERVER_IP:-}" ]; then
  _err2 "缺少必需参数 SERVER_IP。"
  _err2 "用法示例: SERVER_IP=1.2.3.4 sh install_reality.sh"
  exit 1
fi

if [ "$LISTEN_PORT" -eq 0 ]; then
  OUTPUT_PORT=$SERVER_LISTEN_PORT
else
  OUTPUT_PORT=$LISTEN_PORT
fi

### 1. 安装 sing-box(幂等,已装则跳过) ###
# 统一方案:所有系统都用官方静态编译的 linux-<arch>.tar.gz 独立二进制,
# 不依赖系统 libc(glibc/musl 通吃),也绕开 apk/deb 等包管理器的下载&缓存问题。
install_singbox() {
  # 幂等增强: 只有存在且能正常运行时才跳过; 若是坏的(如旧的动态链接二进制跑不起来)则删掉重装
  if command -v sing-box >/dev/null 2>&1; then
    if sing-box version >/dev/null 2>&1; then
      _ok2 "sing-box 已安装且可运行,跳过 ($(sing-box version 2>&1 | head -n1 | tr -s ' '))"
      return
    else
      _err2 "检测到 sing-box 存在但无法运行(可能是旧的动态链接残留),重新安装 ..."
      rm -f "$(command -v sing-box)"
    fi
  fi
  _info2 "安装 sing-box(静态二进制 tar.gz) ..."

  # --- 架构映射: uname -m -> 官方 tar.gz 命名 ---
  local raw_arch gh_arch
  raw_arch=$(uname -m)
  case "$raw_arch" in
    x86_64|amd64)           gh_arch="amd64" ;;
    aarch64|arm64)          gh_arch="arm64" ;;
    i386|i486|i586|i686)    gh_arch="386" ;;
    armv7l|armv6l|armhf)    gh_arch="armv7" ;;
    riscv64)                gh_arch="riscv64" ;;
    s390x)                  gh_arch="s390x" ;;
    *)
      _err2 "暂不支持/未知架构: $raw_arch"
      _err2 "请到 https://github.com/SagerNet/sing-box/releases 手动安装对应版本"
      exit 1
      ;;
  esac

  # --- 获取最新版本号 ---
  local download_version
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

  # --- 下载 tar.gz (优先 -musl 静态版;若该变体不存在则回退无后缀版) ---
  local tarball tarball_url tmpdir
  tmpdir="/tmp/singbox-install.$$"
  mkdir -p "$tmpdir"

  # 优先: -musl 静态编译版,不依赖系统 libc/动态加载器,全平台通吃
  tarball="sing-box-${download_version}-linux-${gh_arch}-musl.tar.gz"
  tarball_url="https://github.com/SagerNet/sing-box/releases/download/v${download_version}/${tarball}"
  _info2 "下载 $tarball_url"
  if curl -fsSL -o "$tmpdir/$tarball" "$tarball_url"; then
    :
  else
    # 回退: 无后缀版(该变体在该版本/架构可能未发布)
    tarball="sing-box-${download_version}-linux-${gh_arch}.tar.gz"
    tarball_url="https://github.com/SagerNet/sing-box/releases/download/v${download_version}/${tarball}"
    _info2 "[-musl 变体下载失败,回退无后缀版] 下载 $tarball_url"
    if ! curl -fsSL -o "$tmpdir/$tarball" "$tarball_url"; then
      _err2 "下载 sing-box 失败: $tarball_url"
      _err2 "请检查网络,或在配置代理后重试"
      rm -rf "$tmpdir"
      exit 1
    fi
    _err2 "注意:已回退到无后缀版(可能为动态链接),若运行报 required file not found 请改用含 -musl 的版本"
  fi

  # --- 校验 gzip 有效性(避免残缺文件) ---
  if ! gzip -t "$tmpdir/$tarball" 2>/dev/null; then
    _err2 "下载的安装包不完整或损坏,请检查网络后重试"
    rm -rf "$tmpdir"
    exit 1
  fi

  # --- 解压并安装二进制 ---
  if ! tar -xzf "$tmpdir/$tarball" -C "$tmpdir"; then
    _err2 "解压失败,安装包可能损坏"
    rm -rf "$tmpdir"
    exit 1
  fi
  local bin_file bin_dir
  bin_file=$(find "$tmpdir" -maxdepth 2 -type f -name sing-box 2>/dev/null | head -n1)
  if [ -z "$bin_file" ]; then
    _err2 "未在安装包内找到 sing-box 可执行文件"
    rm -rf "$tmpdir"
    exit 1
  fi
  bin_dir=$(dirname "$bin_file")
  install -m 755 "$bin_dir/sing-box" /usr/local/bin/sing-box
  rm -rf "$tmpdir"

  # --- 验证安装 ---
  if ! command -v sing-box >/dev/null 2>&1 || ! sing-box version >/dev/null 2>&1; then
    _err2 "sing-box 安装后无法运行,请手动排查"
    exit 1
  fi
  _ok2 "sing-box 安装完成: $(sing-box version 2>&1 | head -n1)"
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
  "log": { "level": "warn", "output": "/var/log/sing-box.log", "timestamp": true },
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
# 注意: 我们是手动解压二进制安装,系统里没有包管理器生成的 init 脚本,
# 必须自己创建 systemd/openrc 服务定义,否则无法自启动/启动。
start_service() {
  local bin_path
  if ! command -v sing-box >/dev/null 2>&1; then
    bin_path="/usr/local/bin/sing-box"
  else
    bin_path="$(command -v sing-box)"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    # ---- systemd ----
    _info2 "创建 systemd 服务定义 ..."
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target

[Service]
ExecStart=${bin_path} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1
    # enable 失败不应中止(set -e),否则重启都无法执行
    systemctl enable sing-box >/dev/null 2>&1 || true
    if systemctl restart sing-box; then
      _ok2 "已通过 systemd 启动 sing-box"
    else
      _err2 "systemd 启动 sing-box 失败,请手动查看: journalctl -u sing-box -n 30"
    fi
  elif command -v rc-service >/dev/null 2>&1; then
    # ---- openrc (Alpine 等) ----
    _info2 "创建 openrc 服务定义 ..."
    cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
name="sing-box"
description="sing-box proxy service"
command="${bin_path}"
command_args="run -c ${CONFIG_FILE}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
EOF
    chmod +x /etc/init.d/sing-box
    # add 失败不应中止(set -e),否则 start 都无法执行
    rc-update add sing-box default >/dev/null 2>&1 || true
    if rc-service sing-box start; then
      _ok2 "已通过 openrc 启动 sing-box"
    else
      _err2 "openrc 启动 sing-box 失败,请手动查看: rc-service sing-box status"
    fi
  else
    _err2 "未识别到 systemd/openrc,请手动启动 sing-box: $bin_path run -c $CONFIG_FILE"
  fi
}

### 5.1 配置日志轮转(logrotate) ###
setup_logrotate() {
  _info2 "配置日志轮转(logrotate) ..."
  cat > /etc/logrotate.d/sing-box <<'EOF'
/var/log/sing-box.log {
    daily
    rotate 3
    compress
    maxsize 10M
    missingok
    notifempty
    copytruncate
}
EOF

  # 各系统安装 logrotate(自动识别包管理器)
  if _cmd apk; then
    apk add --no-cache logrotate >/dev/null 2>&1 || true
  elif _cmd apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y logrotate >/dev/null 2>&1 || true
  elif _cmd dnf; then
    dnf install -y logrotate >/dev/null 2>&1 || true
  elif _cmd yum; then
    yum install -y logrotate >/dev/null 2>&1 || true
  elif _cmd zypper; then
    zypper --non-interactive install logrotate >/dev/null 2>&1 || true
  fi

  # 关键区别:
  # - Debian/Ubuntu: 装 logrotate 自带 /etc/cron.daily 定时,无需额外处理
  # - Alpine: logrotate 不会自动调度,需放进 crond 的 daily 周期
  if _cmd apk; then
    local periodic=/etc/periodic/daily/logrotate
    cat > "$periodic" <<'EOF'
#!/bin/sh
/usr/sbin/logrotate /etc/logrotate.conf >/dev/null 2>&1
EOF
    chmod +x "$periodic"
    rc-service crond start >/dev/null 2>&1 || true
  fi

  _ok2 "日志轮转已配置:单文件>10M 或每日轮转,保留3份并压缩,上限约30M"
}

### 6. 输出 vless 链接 + JSON + YAML,并存档一份 ###
print_result() {
  local ip="$RESOLVED_IP"
  local link="vless://${UUID}@${ip}:${OUTPUT_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${NODE_NAME}"

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

    echo ""
    echo "============ Clash / Mihomo 客户端 YAML ============"
    cat <<EOF
  - name: ${NODE_NAME}
    type: vless
    server: ${ip}
    port: ${OUTPUT_PORT}
    uuid: ${UUID}
    flow: xtls-rprx-vision
    tls: true
    servername: ${REALITY_SERVER_NAME}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
    network: tcp
EOF
    echo "=============================================="
  } | tee "${CONFIG_DIR}/node_output.txt"
}

### 7. 写入 shownode / log 快捷指令(同时兼容 bash 和 Alpine 的 ash) ###
setup_alias() {
  local alias_line="alias shownode='cat ${CONFIG_DIR}/node_output.txt'"
  local log_line
  log_line="alias log='tail -n 100 /var/log/sing-box.log; echo \"[轮转档案]\"; ls -lh /var/log/sing-box.log* 2>/dev/null'"
  for rc in ~/.bashrc ~/.profile; do
    touch "$rc"
    if ! grep -qxF "$alias_line" "$rc" 2>/dev/null; then
      echo "$alias_line" >> "$rc"
    fi
    if ! grep -qxF "$log_line" "$rc" 2>/dev/null; then
      echo "$log_line" >> "$rc"
    fi
  done
}

### 8. 生成 ed25519 SSH 密钥(公钥入服务器,私钥打印后即删) ###
setup_ssh_key() {
  _info2 "配置 SSH 密钥登录(ed25519) ..."
  local key_file="/root/.ssh/id_ed25519"
  local pub_file="/root/.ssh/id_ed25519.pub"
  local auth_file="/root/.ssh/authorized_keys"

  # 如需强制重新生成(例如私钥丢失): SSH_KEY_REGENERATE=1 sh install_reality.sh
  if [ -n "${SSH_KEY_REGENERATE:-}" ]; then
    _warn2 "检测到 SSH_KEY_REGENERATE,删除现有密钥并重新生成 ..."
    rm -f "$key_file" "$pub_file"
    sed -i '\#^ssh-ed25519 #d' "$auth_file" 2>/dev/null || true
  fi

  # 确保 ssh-keygen 可用
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    if _cmd apk; then apk add --no-cache openssh >/dev/null 2>&1 || true
    elif _cmd apt-get; then DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-client >/dev/null 2>&1 || true
    fi
  fi

  mkdir -p /root/.ssh
  chmod 700 /root/.ssh

  # 幂等: 以公钥是否存在为准(私钥打印后被删除,故不能用私钥判断)
  if [ -f "$pub_file" ]; then
    _info2 "检测到已有 SSH 公钥 $pub_file,跳过生成(不会覆盖你已保存的私钥)"
    return
  fi

  ssh-keygen -t ed25519 -f "$key_file" -N "" -C "root@$(hostname)" >/dev/null

  # 公钥写进 authorized_keys(验签只需公钥)
  grep -qF "$(cat "$pub_file")" "$auth_file" 2>/dev/null || cat "$pub_file" >> "$auth_file"
  chmod 600 "$auth_file"

  # 打印私钥(仅在首次生成时出现一次,不写入任何文件)
  echo ""
  echo "================ SSH 私钥(仅此一次,请立即存入 Termius) ================"
  cat "$key_file"
  echo "========================================================================="
  echo ""
  _warn2 "以上是 SSH 私钥,只显示这一次,现在将从服务器删除,请务必先保存好!"

  # 删除服务器上的私钥,只留公钥(服务器验签用不到私钥)
  rm -f "$key_file"
  _ok2 "SSH 公钥已写入 $auth_file;私钥已从服务器删除"
  _warn2 "为兜底,密码登录保持开启;请先用私钥在 Termius 登录成功后,再手动关闭密码登录"
}

### 8.1 关闭密码登录(交互式:先现场校验为 no 再真正生效) ###
# 背景: OpenSSH 的 sshd_config 是"先出现的值生效"(first-match-wins),
# 不是后写的覆盖前面。很多系统(Debian/Ubuntu 尤其)会在
# /etc/ssh/sshd_config.d/*.conf 里放 PasswordAuthentication yes,排在前面,
# 于是你手写的 no 反而被静默覆盖——这就是"明明关了却没关掉"的根因。
# 解决办法: 写入排序最靠前的 drop-in(00-),抢在 before 让 no 最先生效,
# 并在重启后自动用 sshd -T 校验真实生效值,而不是盲目信任配置。
disable_password_login() {
  _info2 "检查是否可以安全关闭密码登录 ..."

  # --- 安全闸门:没有可用公钥就绝不关闭(私钥已删,靠公钥验签) ---
  local auth_file="/root/.ssh/authorized_keys"
  if [ ! -f "$auth_file" ] || ! grep -qE "ssh-ed25519|ssh-rsa|ecdsa|ssh-dss" "$auth_file" 2>/dev/null; then
    _warn2 "authorized_keys 中没有公钥,为避免锁死,跳过关闭密码登录。"
    _warn2 "请先确认密钥登录可用后再手动执行。"
    return
  fi

  local conf_file="/etc/ssh/sshd_config"
  local drop_dir="/etc/ssh/sshd_config.d"
  local drop_file="$drop_dir/00-disable-password.conf"
  local include_line="Include ${drop_dir}/*.conf"

  # --- ① 写入最优先的 drop-in(00- 确保 first-match-wins 生效) ---
  mkdir -p "$drop_dir"
  printf '%s\n' \
    "PasswordAuthentication no" \
    "KbdInteractiveAuthentication no" \
    "ChallengeResponseAuthentication no" > "$drop_file"
  _ok2 "已写入 $drop_file"

  # --- ② 确保主配置在最顶 include 该目录(Alpine/老系统可能没有) ---
  if ! grep -qE "^[[:space:]]*Include .*sshd_config\.d" "$conf_file" 2>/dev/null; then
    _info2 "主配置缺少 include 语句,在最顶部补上 ..."
    local tmp_conf="/tmp/sshd_config.$$"
    {
      echo "$include_line"
      cat "$conf_file"
    } > "$tmp_conf"
    install -m 600 "$tmp_conf" "$conf_file"
    rm -f "$tmp_conf"
    _ok2 "已在 $conf_file 顶部插入 $include_line"
  fi

  # --- ③ sshd -t 语法检查(安全闸门,不过就回滚,绝不锁死) ---
  if ! sshd -t >/dev/null 2>&1; then
    _err2 "新配置语法检查失败,回滚并取消关闭密码登录:"
    _err2 "  sshd -t"
    rm -f "$drop_file"
    exit 1
  fi

  # --- ④ 交互确认:让你现场验证 sshd -T 为 no ---
  echo ""
  echo "================ 关闭密码登录前请现场确认 ================"
  echo "请先到另一个 SSH 窗口/会话完成以下两步:"
  echo "  1) 用密钥登录一次,确认密钥登录可用"
  echo "  2) 执行:  sshd -T | grep -iE 'password|kbdinteractive|challengeresponse'"
  echo "     关键的 PasswordAuthentication 必须为 no(决定密码登录已关)。"
  echo "     KbdInteractive/ChallengeResponse 若不出现属正常:"
  echo "     新版 OpenSSH(9.8+)已移除 ChallengeResponse,该行不存在即视为通过。"
  echo "确认 PasswordAuthentication=no 后,输入 yes 才会真正关闭并重启 sshd;"
  echo "输入其他任意内容则跳过,不关闭密码登录。"
  echo "==========================================================="
  local confirm=""
  # 用 /dev/tty 从真实终端读取:管道模式(如 | ... sh)下 stdin 被占用,
  # 但 /dev/tty 仍指向你的 SSH 终端,因此交互确认在两种执行方式下都可用。
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf '%s' "请输入 yes 关闭密码登录 > "
    read -r confirm < /dev/tty || true
  else
    _info2 "未检测到可交互终端(/dev/tty),跳过关闭密码登录(保持现状)。"
  fi
  if [ "$confirm" != "yes" ]; then
    _warn2 "未确认,跳过关闭密码登录(保持现状,仍可用密码登录)。"
    return
  fi

  # --- ⑤ 重启 sshd(自动识别 systemd / openrc) ---
  _info2 "正在重启 sshd 使配置生效 ..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || {
      _err2 "systemd 重启 sshd 失败,请手动: systemctl restart sshd"
      return 1
    }
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service sshd restart >/dev/null 2>&1 || rc-service ssh restart >/dev/null 2>&1 || {
      _err2 "openrc 重启 sshd 失败,请手动: rc-service sshd restart"
      return 1
    }
  else
    _err2 "未识别 systemd/openrc,请手动重启 sshd 后继续。"
    return 1
  fi
  _ok2 "sshd 已重启"

  # --- ⑥ 自动校验真实生效值 ---
  # 注意: Pillar 是 PasswordAuthentication,kbdinteractive 为辅助;
  # ChallengeResponse 在新版 OpenSSH(9.8+)已移除,不存在也算通过。
  _info2 "自动校验实际生效的认证设置 ..."
  local pa kbd cr
  pa=$(sshd -T 2>/dev/null | awk -F' ' '/^passwordauthentication/{print $2}')
  kbd=$(sshd -T 2>/dev/null | awk -F' ' '/^kbdinteractiveauthentication/{print $2}')
  cr=$(sshd -T 2>/dev/null | awk -F' ' '/^challengeresponseauthentication/{print $2}')
  echo "  PasswordAuthentication=$pa  KbdInteractiveAuthentication=${kbd:-(不存在,旧版)}  ChallengeResponseAuthentication=${cr:-(不存在,9.8+已移除,视为通过)}"
  # ChallengeResponse 为空(该指令在新版已移除)时视为通过
  if [ "$pa" = "no" ] && [ "$kbd" = "no" ] && { [ "$cr" = "no" ] || [ -z "$cr" ]; }; then
    _ok2 "校验通过:密码登录已确认为关闭。"
  else
    _err2 "校验失败:密钥登录可能仍为开启(pa=$pa kbd=$kbd cr=$cr)。"
    _err2 "请手动复核: sshd -T | grep -iE 'password|kbdinteractive|challengeresponse'"
  fi

  # --- ⑦ 最终你肉眼复核 ---
  echo ""
  _info2 "请再肉眼确认一次以下输出(PasswordAuthentication 应为 no):"
  sshd -T 2>/dev/null | grep -iE 'passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication' || true
  _ok2 "关闭密码登录流程结束。请用另一窗口验证:密码登录已失效、密钥登录正常。"
}

install_singbox
generate_credentials
RESOLVED_IP="$SERVER_IP"
write_config
check_and_open_firewall
start_service
setup_logrotate
print_result
setup_alias
setup_ssh_key
disable_password_login
echo ""
_ok2 "已写入 shownode 快捷指令,重新连一次SSH(或执行 source ~/.bashrc)后即可用 shownode 查看节点信息"
