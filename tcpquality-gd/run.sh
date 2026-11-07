#!/usr/bin/env bash
# Low-volume Guangdong Telecom/Mobile IPv4 comparison with guided setup.
set -Eeuo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CORE="$HERE/runTcpQuality-core.sh"
DATA_DIR=${TCPQUALITY_GD_DATA_DIR:-/root/tcpquality-gd-compare}
MODE=${1:-help}
ARG=${2:-}
CORE_COMMIT='ac6cda0b833836b5e746800e5b2a9c9f29169230'
CORE_SHA256='0b3a2070ba7bd410304a7877b42d58d80cd467422c01b74d46f512cb0b9d6ee1'
CORE_URL="https://raw.githubusercontent.com/hytuytujyt/script/$CORE_COMMIT/tcpquality-gd/runTcpQuality-core.sh"
TCPFIT_VERSION='0.5.9'
TCPFIT_SHA256='8331cc40950229a3280ce32406330a85b1a3d21ba398a4db3dc7e25c39783741'
TCPFIT_URL="https://raw.githubusercontent.com/Kylin010/tcpfit/v$TCPFIT_VERSION/tcpfit.sh"

usage() {
  cat <<EOF
广东电信/移动低流量前后对比

用法（root）：
  $0 baseline       自动准备依赖与 tcpfit，然后做调优前测试
  $0 tune <Mbps>    只做 tcpfit 基础调优，例如：$0 tune 200
  $0 after          调优后测试（要求已有 baseline 和 tune 记录）
  $0 compare        对比已保存的两轮报告
  $0 setup          只安装/检查依赖、TcpQuality core 和 tcpfit，不执行测速
  RESET=YES $0 reset 清除本比较记录（不回滚 tcpfit）

测试范围固定：广东电信/移动 IPv4 普通回程、大包回程、VPS→广东单线程下载。
不测联通、IPv6、上传、其他地区、教育网、国际互联、Apple CDN，也不上传报告。
单线程下载最多 64 MiB/运营商/轮；每次还设 10 秒超时。依赖安装和其他流量不计入此载荷上限。
首次 baseline 会提示后自动安装缺少的系统依赖、NextTrace Tiny、TcpQuality core 与 tcpfit。
EOF
}

fail() { printf '[!] %s\n' "$*" >&2; exit 1; }
require_root() { [[ "$(id -u)" == 0 ]] || fail '请以 root 运行。'; }

traffic_bytes() {
  local rx=0 tx=0 iface="$1"
  if [[ -n "$iface" && -r "/sys/class/net/$iface/statistics/rx_bytes" ]]; then
    read -r rx < "/sys/class/net/$iface/statistics/rx_bytes" || rx=0
    read -r tx < "/sys/class/net/$iface/statistics/tx_bytes" || tx=0
  fi
  [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
  [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
  printf '%s\n' "$((rx + tx))"
}

os_id() {
  [[ -r /etc/os-release ]] || return 1
  . /etc/os-release
  printf '%s' "${ID:-unknown}"
}

missing_tools() {
  local c
  for c in curl ip nstat nping traceroute awk sha256sum; do
    command -v "$c" >/dev/null 2>&1 || printf '%s\n' "$c"
  done
}

confirm_setup() {
  local missing="$1" need_tcpfit="$2" need_core="$3" answer
  printf '\n首次准备需要网络下载/安装：\n'
  [[ -z "$missing" ]] || printf '  系统工具：%s\n' "${missing//$'\n'/, }"
  [[ "$need_tcpfit" == 0 ]] || printf '  官方 tcpfit v%s（下载后校验 SHA256；不运行测速）\n' "$TCPFIT_VERSION"
  [[ "$need_core" == 0 ]] || printf '  已固定版本并校验 SHA256 的 TcpQuality core\n'
  if [[ ! -t 0 ]]; then
    [[ "${AUTO_INSTALL:-0}" == 1 ]] || fail '非交互运行时如同意安装，请设置 AUTO_INSTALL=1。'
    return 0
  fi
  read -r -p '继续安装？[y/N] ' answer
  [[ "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]] || fail '已取消；没有开始测试。'
}

install_system_deps() {
  local id="$1" missing="$2"
  [[ -n "$missing" ]] || return 0
  case "$id" in
    debian|ubuntu)
      command -v apt-get >/dev/null 2>&1 || fail '系统识别为 Debian/Ubuntu，但找不到 apt-get。'
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y nmap traceroute iproute2 curl ca-certificates
      ;;
    alpine)
      command -v apk >/dev/null 2>&1 || fail '系统识别为 Alpine，但找不到 apk。'
      apk add --no-cache bash coreutils nmap-nping traceroute iproute2 curl ca-certificates
      ;;
    *) fail "暂不自动安装 $id 的依赖；请手动安装：curl、iproute2(nstat)、nping、traceroute、awk、sha256sum。" ;;
  esac
}

install_nexttrace_tiny() {
  local installer
  command -v nexttrace-tiny >/dev/null 2>&1 && return 0
  installer=$(mktemp "${TMPDIR:-/tmp}/nexttrace-installer.XXXXXX") || return 1
  if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 90 https://nxtrace.org/nt -o "$installer"; then
    rm -f "$installer"; return 1
  fi
  bash "$installer" --flavor tiny
  rm -f "$installer"
  command -v nexttrace-tiny >/dev/null 2>&1
}

install_tcpfit() {
  local tmp
  command -v tcpfit >/dev/null 2>&1 && return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/tcpfit.XXXXXX") || return 1
  if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 90 "$TCPFIT_URL" -o "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  if ! printf '%s  %s\n' "$TCPFIT_SHA256" "$tmp" | sha256sum -c - >/dev/null 2>&1; then
    rm -f "$tmp"; fail "tcpfit v$TCPFIT_VERSION SHA256 校验失败，拒绝安装。"
  fi
  install -m 755 "$tmp" /usr/local/bin/tcpfit
  rm -f "$tmp"
  command -v tcpfit >/dev/null 2>&1
}

install_core() {
  local tmp
  if [[ -s "$CORE" ]]; then return 0; fi
  mkdir -p "$DATA_DIR"
  chmod 700 "$DATA_DIR"
  tmp="$DATA_DIR/runTcpQuality-core.sh.tmp"
  curl -fsSL --retry 2 --connect-timeout 10 --max-time 90 "$CORE_URL" -o "$tmp" || {
    rm -f "$tmp"; fail '下载 TcpQuality core 失败。';
  }
  if ! printf '%s  %s\n' "$CORE_SHA256" "$tmp" | sha256sum -c - >/dev/null 2>&1; then
    rm -f "$tmp"; fail 'TcpQuality core SHA256 校验失败，已拒绝运行。';
  fi
  mv -f "$tmp" "$DATA_DIR/runTcpQuality-core.sh"
  chmod 600 "$DATA_DIR/runTcpQuality-core.sh"
  CORE="$DATA_DIR/runTcpQuality-core.sh"
}

prepare() {
  local id missing need_tcpfit=0 need_core=0
  require_root
  id=$(os_id) || fail '无法读取 /etc/os-release。'
  missing=$(missing_tools || true)
  command -v tcpfit >/dev/null 2>&1 || need_tcpfit=1
  [[ -s "$CORE" || -s "$DATA_DIR/runTcpQuality-core.sh" ]] || need_core=1
  if [[ -n "$missing" || ! -x "$(command -v nexttrace-tiny 2>/dev/null || true)" || "$need_tcpfit" == 1 || "$need_core" == 1 ]]; then
    confirm_setup "$missing$([[ -x "$(command -v nexttrace-tiny 2>/dev/null || true)" ]] || printf '\nnexttrace-tiny')" "$need_tcpfit" "$need_core"
  fi
  install_system_deps "$id" "$missing"
  local still_missing
  still_missing=$(missing_tools || true)
  [[ -z "$still_missing" ]] || fail "仍缺少系统工具：${still_missing//$'\n'/, }"
  install_nexttrace_tiny || fail '安装 NextTrace Tiny 失败；需要可执行命令 nexttrace-tiny。'
  install_tcpfit || fail '安装 tcpfit 失败。'
  if [[ -s "$DATA_DIR/runTcpQuality-core.sh" ]]; then CORE="$DATA_DIR/runTcpQuality-core.sh"; else install_core; fi
  printf '[OK] 系统依赖、NextTrace Tiny、tcpfit 和 TcpQuality core 已就绪。\n'
}

case "$MODE" in
  help|-h|--help) usage; exit 0 ;;
  reset)
    [[ "${RESET:-}" == YES ]] || fail "拒绝清除记录；如确认，运行 RESET=YES $0 reset。此操作不会回滚 tcpfit。"
    rm -rf -- "$DATA_DIR"
    printf '已清除 %s（不会卸载依赖或回滚 tcpfit）。\n' "$DATA_DIR"
    exit 0
    ;;
  compare)
    [[ -s "$DATA_DIR/baseline.csv" && -s "$DATA_DIR/after.csv" ]] || fail "缺少 baseline/after CSV；记录目录：$DATA_DIR"
    for stage in baseline after; do
      printf '\n===== %s：%s =====\n' "$stage" "$(cat "$DATA_DIR/$stage.time" 2>/dev/null || echo 未知)"
      awk -F, '/^三网,IPv4,广东,(电信|移动),/ || /^IPv4大包,IPv4,广东,(电信|移动),/ || /^三网单线程速度,广东,(电信|移动),/ {print}' "$DATA_DIR/$stage.csv" || true
    done
    printf '\n完整日志和 CSV：%s\n' "$DATA_DIR"
    exit 0
    ;;
  baseline|after|setup|tune) ;;
  *) usage >&2; exit 2 ;;
esac

require_root
if [[ "$MODE" == tune ]]; then
  [[ "$ARG" =~ ^[1-9][0-9]{0,5}$ ]] || fail "请提供套餐带宽 Mbps，例如：$0 tune 200。不要留空或使用 auto。"
  [[ -s "$DATA_DIR/baseline.csv" ]] || fail '请先执行 baseline 并保存调优前记录。'
  [[ ! -e "$DATA_DIR/tune.done" ]] || fail '基础调优已记录；拒绝重复执行。需要重做请先备份并重置比较记录。'
elif [[ "$MODE" == baseline ]]; then
  [[ ! -e "$DATA_DIR/baseline.csv" ]] || fail "基线已存在：$DATA_DIR/baseline.csv；拒绝重复测速。"
elif [[ "$MODE" == after ]]; then
  [[ -s "$DATA_DIR/baseline.csv" ]] || fail '请先执行 baseline。'
  [[ -s "$DATA_DIR/tune.done" ]] || fail "请先运行本脚本的 tune <Mbps>；确保基础调优完成后才复测。"
  [[ ! -e "$DATA_DIR/after.csv" ]] || fail "调优后记录已存在：$DATA_DIR/after.csv；拒绝重复测速。"
fi
prepare
mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR"

if [[ "$MODE" == setup ]]; then exit 0; fi

if [[ "$MODE" == tune ]]; then
  printf '[*] 执行 tcpfit 基础调优：proxy，%s Mbps；不运行 probe 或 sweep。\n' "$ARG"
  if ! tcpfit tune --role proxy --bw "$ARG" >"$DATA_DIR/tune.log" 2>&1; then
    tail -n 60 "$DATA_DIR/tune.log" >&2 || true
    fail 'tcpfit 基础调优失败；没有写入 tune.done 标记，请检查日志。'
  fi
  cat "$DATA_DIR/tune.log"
  printf 'bandwidth_mbps=%s\n' "$ARG" > "$DATA_DIR/tune.done"
  chmod 600 "$DATA_DIR/tune.log" "$DATA_DIR/tune.done"
  printf '\n[OK] 基础调优完成。现在可运行：%s after\n' "$0"
  exit 0
fi

log="$DATA_DIR/$MODE.log"
csv="$DATA_DIR/$MODE.csv"
iface=$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}' || true)
before=$(traffic_bytes "$iface")
stamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
export TOS_PROBE_SIZE=64MiB
export TOS_TIMEOUT=10
export SPEEDTEST_APPLECDN_ENABLED=0
export TCPQUALITY_TCP_INFO=0
export TCPQUALITY_RETRANS_TRACE=0

printf '[%s] 开始广东电信/移动 IPv4 专项测试（%s）\n' "$stamp" "$MODE"
printf '单线程下载上限：每个运营商 64 MiB，另有每次 10 秒超时。\n'
printf '默认网卡 RX+TX 计数包含其他并发流量。\n'
if ! bash "$CORE" --gd-proxy-only --no-rank-upload >"$log" 2>&1; then
  printf '[!] TcpQuality 失败；日志：%s\n' "$log" >&2
  tail -n 50 "$log" >&2 || true
  exit 1
fi
latest=$(ls -t /tmp/zstatic_nping_*.csv 2>/dev/null | head -n 1 || true)
[[ -n "$latest" && -s "$latest" ]] || fail "测试结束但找不到 CSV；查看 $log"
cp -- "$latest" "$csv"
after=$(traffic_bytes "$iface")
bytes=$((after - before))
(( bytes >= 0 )) || bytes=0
printf '%s\n' "$stamp" > "$DATA_DIR/$MODE.time"
printf 'interface=%s\nrx_tx_delta_bytes=%s\n' "${iface:-unknown}" "$bytes" > "$DATA_DIR/$MODE.traffic"
chmod 600 "$log" "$csv" "$DATA_DIR/$MODE.time" "$DATA_DIR/$MODE.traffic"
printf '\n已保存 %s 结果：\n  %s\n  %s\n' "$MODE" "$log" "$csv"
printf '测试期间网卡 RX+TX 增量：%s bytes（含其他并发流量）。\n' "$bytes"
if [[ "$MODE" == baseline ]]; then
  printf '下一步：%s tune <套餐带宽Mbps>，例如 %s tune 200。\n' "$0" "$0"
else
  printf '下一步：%s compare\n' "$0"
fi
printf '\n关键输出：\n'
grep -E 'IPv4大包|单线程测速|广东.*(电信|移动)' "$log" | tail -n 35 || true
