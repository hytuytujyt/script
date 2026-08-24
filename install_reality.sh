#!/bin/sh
# =====================================================================
#  install_reality.sh (单文件自举版 v3)
#  兼容 Alpine / Debian / Ubuntu / Fedora / CentOS / openSUSE 等
#
#  支持两种执行方式:
#    1) 已有本地文件:  sh install_reality.sh   (交互式,含"关闭密码登录"确认)
#    2) 管道直接喂:    wget -qO- <URL> | ... sh
#                      curl -fsSL <URL> | ... sh
#                      busybox wget -qO- <URL> | ... sh   (Alpine等精简系统兜底)
#  无论哪种,脚本都会自动补齐 bash/curl,再自动用 bash 自举执行正文。
#
#  注意: 远程拉取请加超时参数(双栈机器 IPv6 黑洞时,无超时的 wget/curl 会静默卡死十几分钟):
#        推荐: curl -fL --connect-timeout 10 -m 60 -o /tmp/install_reality.sh <URL> && ... sh /tmp/install_reality.sh
#
#  v3 新增【断线免疫】:平时完全按原设计前台执行(实时输出/私钥打印即删/yes 交互);
#  仅当 SSH 连接断开的一瞬间,脚本捕获 SIGHUP 自动转入后台续跑(幂等,从断点继续),
#  日志默认 /root/install_reality.log(可用 INSTALL_LOG 覆盖),tail -f 查看进度。
# =====================================================================

SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh}"

# ---------- 简易打印工具(供引导段与正文共用) ----------
# 用命令替代 echo 传递多行,统一错误输出到 stderr
_info() { printf '%s\n' "[*] $*"; }
_ok()   { printf '%s\n' "[✓] $*"; }
_err()  { printf '%s\n' "[!] $*" >&2; }
_cmd()  { command -v "$1" >/dev/null 2>&1; }

# ---------- 断线免疫:SSH 断开瞬间自动转入后台续跑(平时前台正常执行) ----------
# 机制: SSH/终端断开时内核会给前台进程组发 SIGHUP,脚本捕获后自动 nohup 重启
#       自己(脚本幂等,从断点继续),输出改写到 INSTALL_LOG。
# 正常连接: 完全按原设计前台执行(实时输出/私钥打印即删/yes 交互确认),不写日志。
INSTALL_LOG="${INSTALL_LOG:-/root/install_reality.log}"
if [ -z "${INSTALL_DAEMONIZED:-}" ]; then
  _restart_daemon() {
    _log="${INSTALL_LOG:-/root/install_reality.log}"
    _self=""
    if [ -n "$0" ] && [ -f "$0" ]; then
      _self="$0"
    else
      _tmp_self="/tmp/install_reality_daemon.sh"
      rm -f "$_tmp_self"
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 -m 30 "$SCRIPT_URL" -o "$_tmp_self" 2>/dev/null || rm -f "$_tmp_self"
      elif command -v wget >/dev/null 2>&1; then
        wget -q -T 15 -O "$_tmp_self" "$SCRIPT_URL" 2>/dev/null || rm -f "$_tmp_self"
      elif command -v busybox >/dev/null 2>&1; then
        busybox wget -q -T 15 -O "$_tmp_self" "$SCRIPT_URL" 2>/dev/null || rm -f "$_tmp_self"
      fi
      [ -s "$_tmp_self" ] && _self="$_tmp_self"
    fi
    if [ -n "$_self" ]; then
      INSTALL_DAEMONIZED=1 nohup sh "$_self" "$@" </dev/null >"$_log" 2>&1 &
      printf '%s\n' "[*] SSH 连接已断开,安装已转入后台继续(日志: $_log)。" >&2 || true
    fi
    exit 0
  }
  trap _restart_daemon HUP
fi

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

  # --- 内核自动选择: /tmp 为 tmpfs(内存盘)时用 xray(二进制体积约为 sing-box 一半,小内存容器能装) ---
  # 否则用 sing-box(原方案)。检测结果通过环境变量 KERNEL 传给正文。
  if grep -qE " /tmp tmpfs " /proc/mounts 2>/dev/null; then
    KERNEL="xray"
    _info "检测到 /tmp 为内存盘(tmpfs),自动选用精简内核: xray"
  else
    KERNEL="sing-box"
    _info "检测到 /tmp 为磁盘,自动选用内核: sing-box"
  fi
  export KERNEL

  # 用 bash 重新执行本脚本(正文是 bash 语法)
  if [ -n "$0" ] && [ -f "$0" ]; then
    exec bash "$0" "$@"
  else
    _info "管道模式下自举:下载脚本交 bash 执行 ..."
    _tmp_self="/tmp/install_reality_bootstrap.sh"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL --connect-timeout 10 -m 30 "$SCRIPT_URL" -o "$_tmp_self" || { _err "拉取脚本失败(使用 curl): $SCRIPT_URL"; exit 1; }
    elif command -v wget >/dev/null 2>&1; then
      wget -q -T 15 -O "$_tmp_self" "$SCRIPT_URL" || { _err "拉取脚本失败(使用 wget): $SCRIPT_URL"; exit 1; }
    elif command -v busybox >/dev/null 2>&1; then
      busybox wget -q -T 15 -O "$_tmp_self" "$SCRIPT_URL" || { _err "拉取脚本失败(使用 busybox wget): $SCRIPT_URL"; exit 1; }
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

# 正文重设断线免疫 trap(exec bash 后引导段的 trap 已丢失;此处 $0 必为文件)
if [ -z "${INSTALL_DAEMONIZED:-}" ]; then
  _restart_daemon() {
    _log="${INSTALL_LOG:-/root/install_reality.log}"
    if [ -n "$0" ] && [ -f "$0" ]; then
      INSTALL_DAEMONIZED=1 nohup sh "$0" "$@" </dev/null >"$_log" 2>&1 &
      printf '%s\n' "[*] SSH 连接已断开,安装已转入后台继续(日志: $_log)。" >&2 || true
    fi
    exit 0
  }
  trap _restart_daemon HUP
fi

_info2() { printf '%s\n' "[*] $*"; }
_ok2()   { printf '%s\n' "[✓] $*"; }
_err2()  { printf '%s\n' "[!] $*" >&2; }
_warn2() { printf '%s\n' "[!] $*" >&2; }

# --- 内核自动选择(引导段已检测则沿用;直接 bash 入口则兜底检测) ---
# /tmp 为 tmpfs(内存盘) → xray(体积小一半,小内存容器能装);否则 → sing-box
if [ -z "${KERNEL:-}" ]; then
  if grep -qE " /tmp tmpfs " /proc/mounts 2>/dev/null; then
    KERNEL="xray"
  else
    KERNEL="sing-box"
  fi
fi
_info2 "已选择内核: $KERNEL (/tmp 为内存盘则自动选 xray,否则 sing-box)"

### 可通过环境变量覆盖的配置 ###
# MODE: relay=VLESS Reality 中转节点(默认) | landing=Shadowsocks 落地节点
MODE="${MODE:-relay}"
ACTUAL_LISTEN_PORT="${ACTUAL_LISTEN_PORT:-}"              # 实际监听端口(必填):config.json 的 listen_port
LISTEN_PORT="${LISTEN_PORT:-}"                            # 输出/映射端口(必填):链接 + 防火墙
REALITY_DEST="${REALITY_DEST:-addons.mozilla.org:443}"    # 伪装握手目标
REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-addons.mozilla.org}"
NODE_NAME="${NODE_NAME:-reality-$(hostname)}"    # 节点名(YAML/链接里显示,可用 NODE_NAME 环境变量覆盖)
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"

### MODE 合法性校验:未知值回退到默认 relay ###
case "$MODE" in
  relay|landing) : ;;
  *) _warn2 "未知 MODE=$MODE,回退到默认 relay 模式"; MODE="relay" ;;
esac

# Shadowsocks 落地模式只有 sing-box 实现,强制 sing-box
if [ "$MODE" = "landing" ]; then
  KERNEL="sing-box"
  _info2 "落地模式(SS)仅支持 sing-box,内核强制为 sing-box"
fi

### 必需参数校验:SERVER_IP / ACTUAL_LISTEN_PORT / LISTEN_PORT 全部必填 ###
# 两个端口都由用户显式指定,不做"0=默认"回退。
if [ -z "${SERVER_IP:-}" ]; then
  _err2 "缺少必需参数 SERVER_IP。"
  _err2 "用法示例: MODE=relay ACTUAL_LISTEN_PORT=2053 LISTEN_PORT=62879 SERVER_IP=1.2.3.4 sh install_reality.sh"
  exit 1
fi
if [ -z "$ACTUAL_LISTEN_PORT" ]; then
  _err2 "缺少必需参数 ACTUAL_LISTEN_PORT(实际监听端口,写进 config.json 的 listen_port)。"
  _err2 "用法示例: MODE=relay ACTUAL_LISTEN_PORT=2053 LISTEN_PORT=62879 SERVER_IP=1.2.3.4 sh install_reality.sh"
  exit 1
fi
if [ -z "$LISTEN_PORT" ]; then
  _err2 "缺少必需参数 LISTEN_PORT(输出/映射端口,写进链接与防火墙)。"
  _err2 "用法示例: MODE=relay ACTUAL_LISTEN_PORT=2053 LISTEN_PORT=62879 SERVER_IP=1.2.3.4 sh install_reality.sh"
  exit 1
fi

# 输出/映射端口即 LISTEN_PORT(链接与防火墙统一用它)
OUTPUT_PORT=$LISTEN_PORT

### 0.8 稳健下载:断点续传 + 自动重试(应对 NAT 机器慢速/网关重置下载) ###
# NAT 小鸡到 GitHub 常只有几十 KB/s 且下载中易被网关重置,
# 用 -C - 续传 + 最多 5 次重试,避免一次失败就退出。
robust_download() {
  # $1=URL  $2=输出文件
  local url="$1" out="$2" attempt=1
  while [ "$attempt" -le 5 ]; do
    if [ "$attempt" -gt 1 ]; then
      _info2 "下载中断,第 $attempt/5 次重试(断点续传)..."
    fi
    if curl -fL -C - --retry 3 --retry-delay 2 --connect-timeout 20 -o "$out" "$url"; then
      return 0
    fi
    attempt=$((attempt+1))
    sleep 2
  done
  return 1
}

### 0.9 安装 xray(用于 /tmp 为内存盘的小内存机器,二进制体积约为 sing-box 一半) ###
install_xray() {
  if command -v xray >/dev/null 2>&1 && xray version >/dev/null 2>&1; then
    _ok2 "xray 已安装且可运行,跳过 ($(xray version 2>&1 | head -n1 | tr -s ' '))"
    return
  fi
  # 确保 unzip 可用(解压 xray zip 用)
  if ! _cmd unzip; then
    _info2 "安装 unzip ..."
    if _cmd apk; then apk add --no-cache unzip >/dev/null 2>&1 || true
    elif _cmd apt-get; then DEBIAN_FRONTEND=noninteractive apt-get install -y unzip >/dev/null 2>&1 || true
    elif _cmd dnf; then dnf install -y unzip >/dev/null 2>&1 || true
    elif _cmd yum; then yum install -y unzip >/dev/null 2>&1 || true
    fi
  fi
  # 架构映射(xray 官方 zip 命名与 sing-box 不同)
  local raw_arch xray_arch
  raw_arch=$(uname -m)
  case "$raw_arch" in
    x86_64|amd64)        xray_arch="64" ;;
    aarch64|arm64)       xray_arch="arm64-v8a" ;;
    armv7l|armv6l|armhf) xray_arch="arm32-v7a" ;;
    i386|i486|i586|i686) xray_arch="32" ;;
    riscv64)             xray_arch="riscv64" ;;
    s390x)               xray_arch="s390x" ;;
    *) _err2 "暂不支持/未知架构: $raw_arch"; exit 1 ;;
  esac
  # 用磁盘路径(/var/tmp)解压,避免 tmpfs 内存盘占用容器内存
  local tmpdir zip_url bin_file
  tmpdir="/var/tmp/xray-install.$$"
  mkdir -p "$tmpdir"
  zip_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${xray_arch}.zip"
  _info2 "下载 $zip_url"
  if ! robust_download "$zip_url" "$tmpdir/xray.zip"; then
    _err2 "下载 xray 失败(多次重试后): $zip_url"
    rm -rf "$tmpdir"
    exit 1
  fi
  if ! unzip -t "$tmpdir/xray.zip" >/dev/null 2>&1; then
    _err2 "下载的 xray 安装包不完整或损坏,请检查网络后重试"
    rm -rf "$tmpdir"
    exit 1
  fi
  if ! unzip -o -q "$tmpdir/xray.zip" -d "$tmpdir/pkg"; then
    _err2 "解压 xray 失败"
    rm -rf "$tmpdir"
    exit 1
  fi
  bin_file=$(find "$tmpdir/pkg" -maxdepth 2 -type f -name xray 2>/dev/null | head -n1)
  if [ -z "$bin_file" ]; then
    _err2 "未在安装包内找到 xray 可执行文件"
    rm -rf "$tmpdir"
    exit 1
  fi
  # 落盘校验(源 vs 目标 md5/大小,失败重试3次,防写盘损坏)
  install -m 755 "$bin_file" /usr/local/bin/xray
  local attempt=1 _src_md5 _src_size _tgt_md5 _tgt_size
  while [ "$attempt" -le 3 ]; do
    _src_md5=$(md5sum "$bin_file" 2>/dev/null | awk '{print $1}')
    _src_size=$(stat -c %s "$bin_file" 2>/dev/null)
    _tgt_md5=$(md5sum /usr/local/bin/xray 2>/dev/null | awk '{print $1}')
    _tgt_size=$(stat -c %s /usr/local/bin/xray 2>/dev/null)
    if [ -n "$_src_md5" ] && [ "$_src_md5" = "$_tgt_md5" ] && [ -n "$_src_size" ] && [ "$_src_size" = "$_tgt_size" ]; then
      _ok2 "xray 落盘校验通过 (md5=$_tgt_md5, size=$_tgt_size)"
      break
    fi
    _err2 "检测到落盘损坏(源 $_src_md5/$_src_size vs 目标 $_tgt_md5/$_tgt_size),第 $attempt 次重装 ..."
    rm -f /usr/local/bin/xray
    install -m 755 "$bin_file" /usr/local/bin/xray
    attempt=$((attempt+1))
  done
  if [ "$attempt" -gt 3 ]; then
    _err2 "xray 连续 3 次落盘校验失败,疑似存储/内存问题,请检查或换机器"
    rm -rf "$tmpdir"
    exit 1
  fi
  rm -rf "$tmpdir"
  if ! command -v xray >/dev/null 2>&1 || ! xray version >/dev/null 2>&1; then
    _err2 "xray 安装后无法运行,请手动排查"
    exit 1
  fi
  _ok2 "xray 安装完成: $(xray version 2>&1 | head -n1)"
}

### 0.9.1 生成 xray Reality 密钥 / UUID / short_id(输出与 sing-box 分支同名变量) ###
generate_xray_credentials() {
  _info2 "生成 xray Reality 密钥对与身份信息 ..."
  local key_output
  key_output=$(xray x25519)
  # 兼容新旧输出格式:
  #   新(xray 26.x): PrivateKey: / Password (PublicKey): / Hash32:
  #   旧:            Private key: / Public key:
  PRIVATE_KEY=$(printf '%s\n' "$key_output" | sed -n 's/^PrivateKey: //p')
  [ -z "$PRIVATE_KEY" ] && PRIVATE_KEY=$(printf '%s\n' "$key_output" | sed -n 's/^Private key: //p')
  PUBLIC_KEY=$(printf '%s\n' "$key_output" | sed -n 's/^Password (PublicKey): //p')
  [ -z "$PUBLIC_KEY" ] && PUBLIC_KEY=$(printf '%s\n' "$key_output" | sed -n 's/^Public key: //p')
  UUID=$(cat /proc/sys/kernel/random/uuid)
  SHORT_ID=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    _err2 "xray x25519 密钥提取失败,输出如下:"
    printf '%s\n' "$key_output"
    exit 1
  fi
}

### 0.9.2 写入 xray 服务端配置(/usr/local/etc/xray/config.json) ###
write_xray_config() {
  mkdir -p /usr/local/etc/xray
  local dest_host="${REALITY_DEST%:*}"
  local dest_port="${REALITY_DEST##*:}"
  cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "${LISTEN_ADDR:-0.0.0.0}",
      "port": ${ACTUAL_LISTEN_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${dest_host}:${dest_port}",
          "xver": 0,
          "serverNames": [ "${REALITY_SERVER_NAME}" ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [ "${SHORT_ID}" ]
        }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF
  _ok2 "xray 配置文件已写入 /usr/local/etc/xray/config.json"
  if ! xray run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1; then
    _err2 "xray 配置校验失败,请检查参数"
    exit 1
  fi
  _ok2 "xray 配置校验通过"
}

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
  if ! download_version=$(curl -fsSL --connect-timeout 10 -m 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest \
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
  if ! robust_download "$tarball_url" "$tmpdir/$tarball"; then
    # 回退: 无后缀版(该变体在该版本/架构可能未发布)
    tarball="sing-box-${download_version}-linux-${gh_arch}.tar.gz"
    tarball_url="https://github.com/SagerNet/sing-box/releases/download/v${download_version}/${tarball}"
    _info2 "[-musl 变体下载失败,回退无后缀版] 下载 $tarball_url"
    if ! robust_download "$tarball_url" "$tmpdir/$tarball"; then
      _err2 "下载 sing-box 失败(多次重试后): $tarball_url"
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
  # 落盘校验(源 vs 目标 md5/大小,失败重试3次,防写盘损坏导致二进制跑不起来)
  install -m 755 "$bin_dir/sing-box" /usr/local/bin/sing-box
  local attempt=1 _src_md5 _src_size _tgt_md5 _tgt_size
  while [ "$attempt" -le 3 ]; do
    _src_md5=$(md5sum "$bin_dir/sing-box" 2>/dev/null | awk '{print $1}')
    _src_size=$(stat -c %s "$bin_dir/sing-box" 2>/dev/null)
    _tgt_md5=$(md5sum /usr/local/bin/sing-box 2>/dev/null | awk '{print $1}')
    _tgt_size=$(stat -c %s /usr/local/bin/sing-box 2>/dev/null)
    if [ -n "$_src_md5" ] && [ "$_src_md5" = "$_tgt_md5" ] && [ -n "$_src_size" ] && [ "$_src_size" = "$_tgt_size" ]; then
      _ok2 "sing-box 落盘校验通过 (md5=$_tgt_md5, size=$_tgt_size)"
      break
    fi
    _err2 "检测到落盘损坏(源 $_src_md5/$_src_size vs 目标 $_tgt_md5/$_tgt_size),第 $attempt 次重装 ..."
    rm -f /usr/local/bin/sing-box
    install -m 755 "$bin_dir/sing-box" /usr/local/bin/sing-box
    attempt=$((attempt+1))
  done
  if [ "$attempt" -gt 3 ]; then
    _err2 "sing-box 连续 3 次落盘校验失败,疑似存储/内存问题,请检查或换机器"
    rm -rf "$tmpdir"
    exit 1
  fi
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

### 2.1 Shadowsocks 落地:生成密码与加密方式(可被环境变量覆盖) ###
generate_ss_credentials() {
  _info2 "生成 Shadowsocks 密码(随机) ..."
  SS_METHOD="${SS_METHOD:-aes-128-gcm}"      # 经典加密,兼容性最好
  SS_PASSWORD="${SS_PASSWORD:-$(sing-box generate rand 16 --base64)}"
  _ok2 "Shadowsocks 加密方式: $SS_METHOD"
  _ok2 "Shadowsocks 密码: $SS_PASSWORD"
}

### 2.2 安装 jq(仅用于合并配置:只保留 argo 节点,其余被替换,不影响其它功能) ###
install_jq() {
  if command -v jq >/dev/null 2>&1; then
    _ok2 "jq 已安装,跳过"
    return
  fi
  _info2 "安装 jq(用于合并配置:只保留 argo 节点,其余被替换) ..."
  if _cmd apk; then apk add --no-cache jq >/dev/null 2>&1 || true
  elif _cmd apt-get; then DEBIAN_FRONTEND=noninteractive apt-get install -y jq >/dev/null 2>&1 || true
  elif _cmd dnf; then dnf install -y jq >/dev/null 2>&1 || true
  elif _cmd yum; then yum install -y jq >/dev/null 2>&1 || true
  elif _cmd zypper; then zypper --non-interactive install jq >/dev/null 2>&1 || true
  elif _cmd pacman; then pacman -Sy --noconfirm jq >/dev/null 2>&1 || true
  fi
  if ! command -v jq >/dev/null 2>&1; then
    _err2 "jq 安装失败,无法安全合并已有配置(避免覆盖 argo 等手写节点),请手动安装 jq 后重试(各系统包名均为 jq)"
    exit 1
  fi
  _ok2 "jq 安装完成"
}

### 2.3 合并写入配置(write_config/write_ss_config 共用) ###
# $1 = 本次写入的节点 tag(固定用 reality-in 或 ss-in)
# $2 = 本次生成的新 inbound 的 JSON 字符串
# 逻辑: 若 $CONFIG_FILE 已存在且是合法 JSON -> 先备份 -> 只保留 argo 类节点
#       (vless + websocket transport,或 tag 为 argo-in),其余 inbound 全部清除
#       (包括旧版脚本写的无 tag 的 ss / vless-reality,以及本次所选模式之外的旧节点)
#       -> 再插入本次新生成的 inbound(即所选分支的节点: relay=reality / landing=ss)
#       -> 用 sing-box check 校验通过才落盘,校验失败则放弃本次写入、报错退出。
#       若 $CONFIG_FILE 不存在或不是合法 JSON -> 按原逻辑生成一份全新配置。
merge_write_config() {
  local new_tag="$1" new_inbound_json="$2"
  install_jq

  if [ -s "$CONFIG_FILE" ] && jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
    local backup="${CONFIG_FILE}.bak.$(date +%s)"
    cp "$CONFIG_FILE" "$backup"
    _info2 "检测到已有配置,已备份到 $backup(只保留 argo 节点,其余将被本次所选节点替换)"

    local tmpfile="${CONFIG_FILE}.tmp.$$"
    if ! jq --argjson newin "$new_inbound_json" '
        .inbounds = ((.inbounds // []) | map(select(.tag == "argo-in" or (.type == "vless" and ((.transport // {}).type == "ws"))))) + [$newin]
        | .outbounds = (if ((.outbounds // []) | length) == 0 then [ { "type": "direct" } ] else .outbounds end)
      ' "$CONFIG_FILE" > "$tmpfile" 2>/dev/null; then
      _err2 "jq 合并配置失败,已放弃本次写入,原配置未改动: $CONFIG_FILE"
      rm -f "$tmpfile"
      exit 1
    fi

    if command -v sing-box >/dev/null 2>&1 && ! sing-box check -c "$tmpfile" >/dev/null 2>&1; then
      _err2 "合并后的配置未通过 sing-box check 校验,已放弃本次写入,原配置未改动: $CONFIG_FILE"
      _err2 "备份文件在: $backup (如需排查可对比 $tmpfile)"
      exit 1
    fi

    mv "$tmpfile" "$CONFIG_FILE"
    _ok2 "已合并写入(只保留 argo 节点,其余已被本次所选节点替换)"
  else
    jq -n --argjson newin "$new_inbound_json" '
      { "log": { "level": "warn", "output": "/var/log/sing-box.log", "timestamp": true },
        "inbounds": [ $newin ],
        "outbounds": [ { "type": "direct" } ] }
    ' > "$CONFIG_FILE"
  fi
}

### 3. 写入服务端配置文件(监听端口恒定443) ###
write_config() {
  mkdir -p "$CONFIG_DIR"
  local dest_host="${REALITY_DEST%:*}"
  local dest_port="${REALITY_DEST##*:}"
  local new_inbound
  new_inbound=$(cat <<EOF
{
  "type": "vless",
  "tag": "reality-in",
  "listen": "${LISTEN_ADDR:-0.0.0.0}",
  "listen_port": ${ACTUAL_LISTEN_PORT},
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
EOF
)
  merge_write_config "reality-in" "$new_inbound"
  _ok2 "配置文件已写入 $CONFIG_FILE"
}

### 3.1 Shadowsocks 落地模式:写入服务端配置 ###
# 注意: 落地模式下服务端监听端口必须 = 服务商给你的固定端口。
# 因此实际监听用 ACTUAL_LISTEN_PORT(用户指定),输出链接用 LISTEN_PORT(映射/显示端口)。
write_ss_config() {
  mkdir -p "$CONFIG_DIR"
  local new_inbound
  new_inbound=$(cat <<EOF
{
  "type": "shadowsocks",
  "tag": "ss-in",
  "listen": "${LISTEN_ADDR:-0.0.0.0}",
  "listen_port": ${ACTUAL_LISTEN_PORT},
  "method": "${SS_METHOD}",
  "password": "${SS_PASSWORD}"
}
EOF
)
  merge_write_config "ss-in" "$new_inbound"
  _ok2 "Shadowsocks 配置已写入 $CONFIG_FILE (实际监听端口 $ACTUAL_LISTEN_PORT)"
}

### 4. 检查并放行防火墙 ###
# 两个端口都放行: ACTUAL_LISTEN_PORT(实际监听) 与 OUTPUT_PORT(LISTEN_PORT 输出/映射)。
check_and_open_firewall() {
  local port
  for port in "$ACTUAL_LISTEN_PORT" "$OUTPUT_PORT"; do
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
  done
  _info2 "如果连不上,请检查云厂商控制面板的安全组/防火墙是否放行了端口 $ACTUAL_LISTEN_PORT / $OUTPUT_PORT"
}

### 5. 启动服务(自动识别 systemd / openrc) ###
# 注意: 我们是手动解压二进制安装,系统里没有包管理器生成的 init 脚本,
# 必须自己创建 systemd/openrc 服务定义,否则无法自启动/启动。
start_service() {
  # 按所选内核确定 二进制/配置/服务名
  local bin_path conf_file svc_name
  if [ "$KERNEL" = "xray" ]; then
    bin_path="/usr/local/bin/xray"
    conf_file="/usr/local/etc/xray/config.json"
    svc_name="xray"
  else
    bin_path="/usr/local/bin/sing-box"
    conf_file="/etc/sing-box/config.json"
    svc_name="sing-box"
  fi
  if ! command -v "$(basename "$bin_path")" >/dev/null 2>&1; then
    : # 二进制路径固定,不额外探测
  fi

  if command -v systemctl >/dev/null 2>&1; then
    # ---- systemd ----
    _info2 "创建 systemd 服务定义 ..."
    cat > "/etc/systemd/system/${svc_name}.service" <<EOF
[Unit]
Description=${svc_name} service
After=network.target

[Service]
ExecStart=${bin_path} run -c ${conf_file}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1
    # enable 失败不应中止(set -e),否则重启都无法执行
    systemctl enable "$svc_name" >/dev/null 2>&1 || true
    if systemctl restart "$svc_name"; then
      _ok2 "已通过 systemd 启动 $svc_name"
    else
      _err2 "systemd 启动 $svc_name 失败,请手动查看: journalctl -u $svc_name -n 30"
    fi
  else
    # ---- openrc (Alpine 等) ----
    # Alpine 最小安装可能没有 openrc(rc-service 不存在),先补装,否则服务无法注册/自启
    if command -v apk >/dev/null 2>&1 && ! command -v rc-service >/dev/null 2>&1; then
      _info2 "检测到 Alpine 缺少 openrc,自动安装 ..."
      apk add --no-cache openrc >/dev/null 2>&1 || true
    fi
    if command -v rc-service >/dev/null 2>&1; then
      _info2 "创建 openrc 服务定义 ..."
      cat > "/etc/init.d/${svc_name}" <<EOF
#!/sbin/openrc-run
name="${svc_name}"
description="${svc_name} proxy service"
command="${bin_path}"
command_args="run -c ${conf_file}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
EOF
      chmod +x "/etc/init.d/${svc_name}"
      # add 失败不应中止(set -e),否则 start 都无法执行
      rc-update add "$svc_name" default >/dev/null 2>&1 || true
      # 用 restart 而非 start:重跑脚本会重新生成密钥并重写配置,
      # start 对已运行的服务不会重载配置,会导致新旧密钥不匹配连不上。
      if rc-service "$svc_name" restart; then
        _ok2 "已通过 openrc 启动/重启 $svc_name"
      else
        _err2 "openrc 启动 $svc_name 失败,请手动查看: rc-service $svc_name status"
      fi
    else
      _err2 "openrc 安装后仍不可用,请手动启动 $svc_name: $bin_path run -c $conf_file"
    fi
  fi
}

### 5.1 配置日志轮转(logrotate) ###
setup_logrotate() {
  local svc_name
  if [ "$KERNEL" = "xray" ]; then
    _info2 "xray 不写日志文件,跳过日志轮转配置"
    return
  fi
  svc_name="sing-box"
  _info2 "配置日志轮转(logrotate) ..."
  cat > "/etc/logrotate.d/${svc_name}" <<EOF
/var/log/${svc_name}.log {
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

### 6. 输出连接信息(relay 输出 vless+JSON+YAML,landing 只输出 ss://,并存档一份) ###
print_result() {
  # 存档目录可能不存在(xray 分支不建 /etc/sing-box),先确保存在
  mkdir -p "$CONFIG_DIR"
  local ip="$RESOLVED_IP"
  if [ "$MODE" = "landing" ]; then
    # ---- Shadowsocks 落地:只需 ss:// 链接 ---
    local link="ss://$(printf '%s:%s' "$SS_METHOD" "$SS_PASSWORD" | base64 | tr -d '\n')@${ip}:${OUTPUT_PORT}#${NODE_NAME}"
    {
      echo ""
      echo "================ SS 链接 ================"
      echo "$link"
      echo "========================================"
    } | tee "${CONFIG_DIR}/node_output.txt"
    _ok2 "落地节点(Shadowsocks)连接信息已写入 ${CONFIG_DIR}/node_output.txt"
    return
  fi

  # ---- VLESS Reality 中转:输出链接 + JSON + YAML ----
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

### 6.1 服务端自检:本机直连验证 Reality 握手与出站(不验证外部 NAT 映射) ###
self_check() {
  _info2 "服务端自检:本机直连 127.0.0.1:${ACTUAL_LISTEN_PORT} 验证 Reality 握手与出站 ..."
  local port=$((20000 + RANDOM % 20000))
  local tmpconf="/tmp/selfcheck.$$.json"
  local bin svc logf
  if [ "$KERNEL" = "xray" ]; then
    bin="/usr/local/bin/xray"; svc="xray"; logf="/var/log/xray.log"
    cat > "$tmpconf" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [ { "listen": "127.0.0.1", "port": ${port}, "protocol": "socks", "settings": {} } ],
  "outbounds": [ {
    "protocol": "vless",
    "settings": { "vnext": [ { "address": "127.0.0.1", "port": ${ACTUAL_LISTEN_PORT},
      "users": [ { "id": "${UUID}", "flow": "xtls-rprx-vision", "encryption": "none" } ] } ] },
    "streamSettings": { "network": "tcp", "security": "reality",
      "realitySettings": { "serverName": "${REALITY_SERVER_NAME}", "fingerprint": "chrome",
        "publicKey": "${PUBLIC_KEY}", "shortId": "${SHORT_ID}" } }
  } ]
}
EOF
  else
    bin="/usr/local/bin/sing-box"; svc="sing-box"; logf="/var/log/sing-box.log"
    cat > "$tmpconf" <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [ { "type": "socks", "listen": "127.0.0.1", "listen_port": ${port} } ],
  "outbounds": [ {
    "type": "vless", "tag": "self", "server": "127.0.0.1", "server_port": ${ACTUAL_LISTEN_PORT},
    "uuid": "${UUID}", "flow": "xtls-rprx-vision",
    "tls": { "enabled": true, "server_name": "${REALITY_SERVER_NAME}",
      "utls": { "enabled": true, "fingerprint": "chrome" },
      "reality": { "enabled": true, "public_key": "${PUBLIC_KEY}", "short_id": "${SHORT_ID}" } }
  } ]
}
EOF
  fi
  "$bin" run -c "$tmpconf" >/tmp/selfcheck.$$.log 2>&1 &
  local spid=$!
  # 等待 socks 端口就绪(最多 12 秒,慢速机器上客户端启动可能超过 2 秒)
  local ready=""
  local i
  for i in $(seq 1 12); do
    if (exec 3<>/dev/tcp/127.0.0.1/${port}) 2>/dev/null; then
      ready="yes"
      exec 3<&- 3>&-
      break
    fi
    sleep 1
  done
  local code=""
  if [ -n "$ready" ]; then
    # 多目标兜底: google 204 / cloudflare trace,任一成功即通过(部分网络出口访问 google 受限)
    for url in "https://www.google.com/generate_204" "https://cloudflare.com/cdn-cgi/trace"; do
      code=$(curl -sS -m 8 -x "socks5h://127.0.0.1:${port}" -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || true)
      if [ "$code" = "204" ] || [ "$code" = "200" ]; then
        break
      fi
    done
  fi
  if [ "$code" = "204" ] || [ "$code" = "200" ]; then
    _ok2 "服务端自检通过:Reality 握手 + 出站正常"
  else
    _warn2 "服务端自检未通过(ready=$ready http=$code)。请检查: rc-service $svc status; 客户端日志尾部:"
    tail -n 5 /tmp/selfcheck.$$.log 2>/dev/null || true
  fi
  kill "$spid" 2>/dev/null || true
  rm -f "$tmpconf" /tmp/selfcheck.$$.log
}

### 7. 写入 shownode / sshkey / log 快捷指令(同时兼容 bash 和 Alpine 的 ash) ###
setup_alias() {
  local alias_line="alias shownode='cat ${CONFIG_DIR}/node_output.txt'"
  local sshkey_line="alias sshkey='sh /usr/local/bin/sshkey'"
  local sshkey_line2="alias showsshkey='sh /usr/local/bin/sshkey'"
  # log 快捷指令按所选内核指向对应日志文件(xray 分支不写日志文件,加兜底提示避免报错)
  local log_path log_line
  if [ "$KERNEL" = "xray" ]; then
    log_line="alias log='tail -n 100 /var/log/xray.log 2>/dev/null || echo \"[xray 未写日志文件,排查请用 rc-service xray status\"; echo \"[轮转档案]\"; ls -lh /var/log/xray.log* 2>/dev/null'"
  else
    log_path="/var/log/sing-box.log"
    log_line="alias log='tail -n 100 ${log_path}; echo \"[轮转档案]\"; ls -lh ${log_path}* 2>/dev/null'"
  fi

  # 写入 sshkey 独立脚本: 查看私钥(查看后自动删除) + 自动检查/关闭密码登录
  cat > /usr/local/bin/sshkey <<'SSHKEYEOF'
#!/bin/sh
# sshkey: 查看 SSH 私钥(查看后自动删除) + 自动检查/关闭密码登录
# 用法: sshkey [--check]   --check 只检查密码登录状态,不做任何修改
KEY=/root/.ssh/id_ed25519
AUTH=/root/.ssh/authorized_keys

if [ "$1" != "--check" ]; then
  if [ ! -f "$KEY" ]; then
    echo "[*] 私钥文件不存在(可能已删除或从未保留)"
  else
    echo "================ SSH 私钥 ================"
    cat "$KEY"
    echo "==========================================="
    echo ""
    echo "[*] 私钥已显示。请先复制保存到 Termius 等本地工具。"
    if [ "$1" = "--delete" ]; then
      rm -f "$KEY"
      echo "[*] 已按 --delete 确认,私钥从服务器删除"
    else
      echo -n "[*] 确认已保存? 输入 yes 才删除服务器上的私钥(其他任意键保留) > "
      REPLY=""
      if { exec 4<>/dev/tty; } 2>/dev/null; then
        read -r REPLY <&4 || true
        exec 4<&-
      else
        read -r REPLY || true
      fi
      if [ "$REPLY" = "yes" ]; then
        rm -f "$KEY"
        echo "[*] 私钥已从服务器删除"
      else
        echo "[*] 操作已取消,私钥保留在 $KEY (权限600)"
      fi
    fi
  fi
fi

if [ "$(id -u)" != "0" ]; then
  echo "[!] 非 root 用户,跳过密码登录检查"
  exit 0
fi

PA=$(sshd -T 2>/dev/null | awk -F' ' '/^passwordauthentication/{print $2}')
if [ "$PA" = "no" ]; then
  echo "[*] 密码登录已关闭 (PasswordAuthentication=no),无需处理"
  exit 0
fi
if [ "$1" = "--check" ]; then
  echo "[*] 密码登录当前为开启状态 (PasswordAuthentication=$PA)"
  echo "[*] 直接执行 sshkey 即可自动关闭密码登录"
  exit 0
fi

# 关闭前验证: authorized_keys 有公钥才关,防锁死
if [ ! -f "$AUTH" ] || ! grep -qE "ssh-ed25519|ssh-rsa|ecdsa|ssh-dss" "$AUTH" 2>/dev/null; then
  echo "[!] authorized_keys 中没有公钥,为避免锁死,不自动关闭密码登录"
  exit 0
fi

mkdir -p /etc/ssh/sshd_config.d
printf '%s\n' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' 'ChallengeResponseAuthentication no' > /etc/ssh/sshd_config.d/00-disable-password.conf

if ! grep -qE "^[[:space:]]*Include .*sshd_config\.d" /etc/ssh/sshd_config 2>/dev/null; then
  _tmp="/tmp/sshd_config.$$"
  { echo "Include /etc/ssh/sshd_config.d/*.conf"; cat /etc/ssh/sshd_config; } > "$_tmp"
  install -m 600 "$_tmp" /etc/ssh/sshd_config
  rm -f "$_tmp"
fi

if ! sshd -t >/dev/null 2>&1; then
  echo "[!] sshd 配置语法检查失败,已回滚,未关闭密码登录"
  rm -f /etc/ssh/sshd_config.d/00-disable-password.conf
  exit 1
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
elif command -v rc-service >/dev/null 2>&1; then
  rc-service sshd restart 2>/dev/null || rc-service ssh restart 2>/dev/null
fi

PA2=$(sshd -T 2>/dev/null | awk -F' ' '/^passwordauthentication/{print $2}')
if [ "$PA2" = "no" ]; then
  echo "[*] 密码登录已自动关闭 (PasswordAuthentication=no)"
else
  echo "[!] 关闭未生效,请手动检查: sshd -T | grep -i passwordauthentication"
fi
SSHKEYEOF
  chmod 755 /usr/local/bin/sshkey

  for rc in ~/.bashrc ~/.profile; do
    touch "$rc"
    # 清理旧版残留的 alias log=(日志路径可能随内核变化),避免新旧两行并存
    sed -i '/^alias log=/d' "$rc" 2>/dev/null || true
    if ! grep -qxF "$alias_line" "$rc" 2>/dev/null; then
      echo "$alias_line" >> "$rc"
    fi
    if ! grep -qxF "$sshkey_line" "$rc" 2>/dev/null; then
      echo "$sshkey_line" >> "$rc"
    fi
    if ! grep -qxF "$sshkey_line2" "$rc" 2>/dev/null; then
      echo "$sshkey_line2" >> "$rc"
    fi
    if ! grep -qxF "$log_line" "$rc" 2>/dev/null; then
      echo "$log_line" >> "$rc"
    fi
  done
}

### 8. 生成 ed25519 SSH 密钥(公钥入服务器;前台照旧"打印一次即删",断连转后台时才保留) ###
# 正常前台执行: 完全按原设计,私钥终端打印一次即删。
# 断连转后台续跑: 用户看不到屏幕,私钥保留在 /root/.ssh/id_ed25519(权限600)防止丢失。
# SSH_KEY_DELETE=1 可强制"打印即删"(含后台续跑场景,风险自负)。
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

  # 幂等: 以公钥是否存在为准
  if [ -f "$pub_file" ]; then
    if [ -f "$key_file" ]; then
      _ok2 "检测到已有 SSH 密钥对,跳过生成。私钥在 $key_file"
      _info2 "查看: cat $key_file (或执行 showsshkey);下载到本地保存后建议删除: rm -f $key_file"
    else
      _warn2 "检测到已有公钥但私钥已不存在(无法恢复)。如需重新生成: SSH_KEY_REGENERATE=1 重跑"
    fi
    return
  fi

  ssh-keygen -t ed25519 -f "$key_file" -N "" -C "root@$(hostname)" >/dev/null

  # 公钥写进 authorized_keys(验签只需公钥)
  grep -qF "$(cat "$pub_file")" "$auth_file" 2>/dev/null || cat "$pub_file" >> "$auth_file"
  chmod 600 "$auth_file" "$key_file"

  if [ -n "${SSH_KEY_DELETE:-}" ]; then
    # 显式强制 SSH_KEY_DELETE: 打印一次即删(风险自负,非默认)
    echo ""
    echo "================ SSH 私钥(SSH_KEY_DELETE 强制,打印一次即删) ================"
    cat "$key_file"
    echo "========================================================================="
    echo ""
    _warn2 "你设置了 SSH_KEY_DELETE,私钥显示后将从服务器删除,请务必先保存好!"
    rm -f "$key_file"
    _ok2 "SSH 公钥已写入 $auth_file;私钥已按 SSH_KEY_DELETE 从服务器删除"
  else
    # 默认策略: 私钥保留在服务器(权限600),不自动删除。
    # 前台/后台一致保留,靠 sshkey 按需查看,确认保存后再删除,避免"没有输出/断线"时永久丢失私钥而锁死。
    echo ""
    echo "================ SSH 私钥 ================"
    cat "$key_file"
    echo "=========================================="
    echo ""
    _ok2 "SSH 公钥已写入 $auth_file"
    _ok2 "私钥已保留在服务器 $key_file (权限600),不再自动删除"
    _info2 "重连后执行 sshkey: 查看私钥(确认保存后才删除)并自动检查/关闭密码登录"
    _info2 "请先在 Termius 保存好私钥,服务器上的私钥副本可随时用 sshkey 确认后清理"
  fi
  _info2 "私钥相关输出会写入安装日志(${INSTALL_LOG:-/root/install_reality.log}),保存私钥后请清理该日志"
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

  # --- 断连后台续跑:不自动关闭,保持密码登录(防锁死) ---
  # 由用户重连后主动执行 sshkey: 查看私钥并自动检查/关闭密码登录。
  if [ -n "${INSTALL_DAEMONIZED:-}" ]; then
    _info2 "断连后台续跑模式:为防锁死,不自动关闭密码登录(保持现状)。"
    _info2 "重连后执行 sshkey: 查看私钥(查看后自动删除)并自动检查/关闭密码登录。"
    return
  fi

  # --- 安全闸门①:服务器上必须有私钥文件,才允许关闭密码登录 ---
  # 关闭密码登录后,唯一登录途径就是私钥验证。若私钥已不在服务器上
  # (被 sshkey 删过/从未生成),而你本地也没另存,一关就永久锁死。
  if [ ! -f /root/.ssh/id_ed25519 ]; then
    _warn2 "服务器上找不到私钥文件(/root/.ssh/id_ed25519):"
    _warn2 "  若你本地也未保存过该私钥,关闭密码登录会锁死自己!"
    _warn2 "  本次跳过关闭密码登录(保持现状)。请先用私钥实际登录成功,再考虑关闭密码登录。"
    return
  fi

  # --- 安全闸门②:没有可用公钥就绝不关闭(靠公钥验签) ---
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
    return 1
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
  # 用 exec 3<>/dev/tty 实际打开来判断是否有控制终端,避免无终端时 read 报错。
  if { exec 3<>/dev/tty; } 2>/dev/null; then
    printf '%s' "请输入 yes 关闭密码登录 > "
    read -r confirm <&3 || true
    exec 3<&-
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

if [ "$MODE" = "landing" ]; then
  install_singbox
  generate_ss_credentials
elif [ "$KERNEL" = "xray" ]; then
  install_xray
  generate_xray_credentials
else
  install_singbox
  generate_credentials
fi
RESOLVED_IP="$SERVER_IP"
if [ "$MODE" = "landing" ]; then
  write_ss_config
elif [ "$KERNEL" = "xray" ]; then
  write_xray_config
else
  write_config
fi
check_and_open_firewall
start_service
setup_logrotate
print_result
# Reality 握手自检仅对 relay(VLESS Reality)有意义;SS 落地模式没有 Reality 身份
# (未生成 UUID/PRIVATE_KEY/PUBLIC_KEY/SHORT_ID),强行执行会因引用未定义变量在
# set -u 下直接报错退出,故 SS 模式跳过,后面 SSH 密钥/别名/关密码登录仍正常执行。
if [ "$MODE" != "landing" ]; then
  self_check
fi
setup_alias
setup_ssh_key
disable_password_login || true
echo ""
if [ "$MODE" = "landing" ]; then
  _ok2 "落地节点(Shadowsocks)安装完成。已写入 shownode 快捷指令,可用 shownode 查看 ss:// 链接"
else
  _ok2 "已写入 shownode 快捷指令,重新连一次SSH(或执行 source ~/.bashrc)后即可用 shownode 查看节点信息"
fi