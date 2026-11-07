#!/usr/bin/env bash
# Low-volume, two-pass Guangdong Telecom/Mobile IPv4 comparison using TcpQuality.
set -Eeuo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CORE="$HERE/runTcpQuality-core.sh"
DATA_DIR=${TCPQUALITY_GD_DATA_DIR:-/root/tcpquality-gd-compare}
MODE=${1:-help}

usage() {
  cat <<EOF
Usage:
  $0 baseline   # Run once before tcpfit; refuses to overwrite existing baseline
  $0 after      # Run once after tcpfit tune; requires baseline
  $0 compare    # Show saved Guangdong Telecom/Mobile IPv4 result rows
  RESET=YES $0 reset  # Remove saved comparison (explicit confirmation)

Fixed scope: Guangdong IPv4 normal + large-packet return tests, and single-thread
VPS-to-China downloads for Telecom/Mobile. No Unicom, upload, IPv6, other regions,
CERNET, international, Apple CDN, rank upload, or speed-test report upload.
Single-thread download cap: 64 MiB per ISP per run (four downloads across both runs).
EOF
}

iface=$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}' || true)
traffic_bytes() {
  local rx=0 tx=0
  if [[ -n "$iface" && -r "/sys/class/net/$iface/statistics/rx_bytes" ]]; then
    read -r rx < "/sys/class/net/$iface/statistics/rx_bytes" || rx=0
    read -r tx < "/sys/class/net/$iface/statistics/tx_bytes" || tx=0
  fi
  [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
  [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
  printf '%s\n' "$((rx + tx))"
}

case "$MODE" in
  help|-h|--help) usage; exit 0 ;;
  reset)
    [[ "${RESET:-}" == YES ]] || { echo 'Refusing reset. Run RESET=YES ./run.sh reset'; exit 2; }
    rm -rf -- "$DATA_DIR"
    echo "Removed $DATA_DIR"
    exit 0
    ;;
  baseline|after|compare) ;;
  *) usage >&2; exit 2 ;;
esac

if [[ "$MODE" == compare ]]; then
  [[ -s "$DATA_DIR/baseline.csv" && -s "$DATA_DIR/after.csv" ]] || {
    echo "Need both baseline.csv and after.csv in $DATA_DIR" >&2; exit 1;
  }
  for stage in baseline after; do
    printf '\n===== %s: %s =====\n' "$stage" "$(cat "$DATA_DIR/$stage.time" 2>/dev/null || echo unknown)"
    awk -F, 'BEGIN{IGNORECASE=0} \
      /^三网,IPv4,广东,(电信|移动),/ || \
      /^IPv4大包,IPv4,广东,(电信|移动),/ || \
      /^三网单线程速度,广东,(电信|移动),/ {print}' "$DATA_DIR/$stage.csv" || true
  done
  printf '\nFull logs and CSVs: %s\n' "$DATA_DIR"
  exit 0
fi

[[ "$(id -u)" == 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ -x "$(command -v bash)" ]] || { echo 'bash is required.' >&2; exit 1; }
[[ -s "$CORE" ]] || { echo "Missing bundled TcpQuality core: $CORE" >&2; exit 1; }
missing=()
for cmd in curl ip nstat nping traceroute nexttrace-tiny awk; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if ((${#missing[@]})); then
  printf 'Missing required test tools: %s\\n' "${missing[*]}" >&2
  echo 'Install them before starting the baseline; this runner will not auto-install packages or silently skip large-packet testing.' >&2
  exit 1
fi

if [[ "$MODE" == baseline ]]; then
  [[ ! -e "$DATA_DIR/baseline.csv" ]] || {
    echo "Baseline already exists at $DATA_DIR/baseline.csv; preserve it or use RESET=YES $0 reset to start over." >&2; exit 1;
  }
  mkdir -p "$DATA_DIR"
  chmod 700 "$DATA_DIR"
else
  [[ -s "$DATA_DIR/baseline.csv" ]] || { echo 'Run baseline first; no baseline record found.' >&2; exit 1; }
  [[ ! -e "$DATA_DIR/after.csv" ]] || { echo 'After record already exists; refusing an accidental extra test.' >&2; exit 1; }
fi

log="$DATA_DIR/$MODE.log"
csv="$DATA_DIR/$MODE.csv"
iface=$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}' || true)
before=$(traffic_bytes)
stamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Disable all broad/optional tests in the core's dedicated mode, and fix the
# TOS single-thread object to 64 MiB. This mode never uploads test data.
export TOS_PROBE_SIZE=64MiB
export SPEEDTEST_APPLECDN_ENABLED=0
export TCPQUALITY_TCP_INFO=0
export TCPQUALITY_RETRANS_TRACE=0

printf '[%s] Running Guangdong Telecom/Mobile IPv4-only TcpQuality (%s)\n' "$stamp" "$MODE"
printf 'Fixed single-thread payload budget: 2 carriers x 64 MiB = 128 MiB per pass.\n'
printf 'Other traffic on the VPS interface is included in the counter delta.\n'
if ! bash "$CORE" --gd-proxy-only --no-rank-upload >"$log" 2>&1; then
  echo "TcpQuality failed. Log: $log" >&2
  tail -n 40 "$log" >&2 || true
  exit 1
fi

# TcpQuality writes its CSV to /tmp; preserve the newest one alongside the log.
latest=$(ls -t /tmp/zstatic_nping_*.csv 2>/dev/null | head -n 1 || true)
[[ -n "$latest" && -s "$latest" ]] || { echo 'TcpQuality finished but its CSV was not found.' >&2; exit 1; }
cp -- "$latest" "$csv"
after=$(traffic_bytes)
bytes=$((after - before))
(( bytes >= 0 )) || bytes=0
printf '%s\n' "$stamp" > "$DATA_DIR/$MODE.time"
printf 'interface=%s\nrx_tx_delta_bytes=%s\n' "${iface:-unknown}" "$bytes" > "$DATA_DIR/$MODE.traffic"
chmod 600 "$log" "$csv" "$DATA_DIR/$MODE.time" "$DATA_DIR/$MODE.traffic"
printf '\nSaved %s results:\n  %s\n  %s\n' "$MODE" "$log" "$csv"
printf 'VPS interface RX+TX counter delta during run: %s bytes (includes unrelated traffic).\n' "$bytes"
printf 'Next: %s\n' "$([[ "$MODE" == baseline ]] && echo 'run tcpfit tune --role proxy --bw <Mbps>, then run this script with after' || echo 'run this script with compare')"

# Keep a concise view while retaining the complete original report.
printf '\nKey output lines:\n'
grep -E '回程线路|IPv4大包|单线程测速|广东.*(电信|移动)' "$log" | tail -n 35 || true
