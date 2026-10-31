#!/bin/sh
# sing-box node installer. MODE=reality (default), ss, hy2, both (Reality + HY2).
# All node credentials rotate on each successful run unless a supported password
# environment override is set. TLS pairs may be reused after OpenSSL checks.
# SSH files are preserved by default. SSH_KEY_REGENERATE=1 backs up old key files
# and appends a fresh public key; SSH_KEY_DELETE=1 / sshkey --delete are opt-in.
# Never changes sshd password authentication; HY2 local mode owns one isolated NAT table.
# For safe unit tests: INSTALLER_SOURCE_ONLY=1 source ./install_reality.sh in bash.

# Source-only loading must happen under bash, before bootstrap or any mutation.
if [ "${INSTALLER_SOURCE_ONLY:-0}" = 1 ] && [ -z "${BASH_VERSION:-}" ]; then
  printf '%s\n' 'Source-only testing requires bash; bootstrap was skipped.' >&2
  return 1 2>/dev/null || exit 1
fi

_info2() { printf '[*] %s\n' "$*"; }
_ok2() { printf '[OK] %s\n' "$*"; }
_err2() { printf '[!] %s\n' "$*" >&2; }
_warn2() { _err2 "$@"; }
_cmd() { command -v "$1" >/dev/null 2>&1; }

# POSIX sh -> bash bootstrap (including downloaded/piped execution).
if [ -z "${BASH_VERSION:-}" ]; then
  [ "$(id -u)" = 0 ] || { _err2 'Run as root'; exit 1; }
  if ! _cmd bash || ! _cmd curl; then
    if _cmd apk; then apk add --no-cache bash curl ca-certificates || exit 1
    elif _cmd apt-get; then apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y bash curl ca-certificates || exit 1
    elif _cmd dnf; then dnf install -y bash curl ca-certificates || exit 1
    elif _cmd yum; then yum install -y bash curl ca-certificates || exit 1
    elif _cmd zypper; then zypper --non-interactive install bash curl ca-certificates || exit 1
    elif _cmd pacman; then pacman -Sy --noconfirm bash curl ca-certificates || exit 1
    else _err2 'Install bash and curl first.'; exit 1
    fi
  fi
  if [ -f "$0" ]; then exec bash "$0" "$@"; fi
  _bootstrap=$(mktemp /tmp/install-reality.XXXXXX) || exit 1
  curl -fL --connect-timeout 10 -m 60 "${SCRIPT_URL:-https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh}" -o "$_bootstrap" || { rm -f "$_bootstrap"; exit 1; }
  exec bash "$_bootstrap" "$@"
fi

fail() { _err2 "$*"; return 1; }

normalize_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || { fail "Invalid port: $p (expected 1..65535)"; return 1; }
  # Strip arbitrary leading zeroes before arithmetic, avoiding octal/overflow.
  while [[ ${#p} -gt 1 && "$p" == 0* ]]; do p="${p#0}"; done
  [[ ${#p} -le 5 ]] || { fail "Port outside 1..65535: $p"; return 1; }
  p=$((10#$p))
  (( p >= 1 && p <= 65535 )) || { fail "Port outside 1..65535: $p"; return 1; }
  printf '%s\n' "$p"
}

normalize_hy2_ports() {
  local spec="$1" token start end result='[]' count=0 only=0
  [[ "$spec" =~ ^[0-9,:-]+$ && "$spec" != ,* && "$spec" != *, && "$spec" != *,,* ]] || { fail 'Invalid HY2_SERVER_PORTS list'; return 1; }
  local -a tokens
  IFS=, read -r -a tokens <<< "$spec"
  for token in "${tokens[@]}"; do
    if [[ "$token" =~ ^([0-9]+)([-:])([0-9]+)$ ]]; then
      start=$(normalize_port "${BASH_REMATCH[1]}") || return 1
      end=$(normalize_port "${BASH_REMATCH[3]}") || return 1
    else
      start=$(normalize_port "$token") || return 1
      end="$start"
    fi
    (( start <= end )) || { fail "Reversed HY2 port range: $token"; return 1; }
    only="$start"
    result=$(jq -cn --argjson a "$result" --arg p "$start:$end" '$a + [$p]') || return 1
  done
  # Sort and merge overlapping/adjacent intervals without expanding individual ports.
  local merged
  merged=$(jq -c '[.[]|split(":")|map(tonumber)] | sort_by(.[0],.[1]) | reduce .[] as $x ([]; if length>0 and $x[0]<=.[-1][1]+1 then .[-1][1]=([.[-1][1],$x[1]]|max) else .+[$x] end) | if length>64 then error("HY2 supports at most 64 disjoint intervals") else . end' <<< "$result") || return 1
  HY2_INTERVALS_JSON=$merged
  result=$(jq -c 'map("\(.[0]):\(.[1])")' <<< "$merged") || return 1
  count=$(jq '[.[]|.[1]-.[0]+1]|add' <<< "$merged")
  only=$(jq '.[0][0]' <<< "$merged")
  HY2_PORTS_JSON="$result"
  HY2_PORT_COUNT="$count"
  HY2_SINGLE_PORT="$only"
}

validate_host() {
  # Unbracketed IPv6, IPv4, or DNS name; bracket only at URI rendering time.
  [[ "$1" =~ ^[a-zA-Z0-9_.:-]+$ && "$1" != -* ]] || { fail "Invalid $2: use an unbracketed IP or hostname without whitespace"; return 1; }
}

init_settings() {
  MODE="${MODE:-reality}"
  case "$MODE" in
    reality|ss|hy2|both) ;;
    relay) fail 'MODE=relay was renamed: use MODE=reality'; return 1 ;;
    landing) fail 'MODE=landing was renamed: use MODE=ss'; return 1 ;;
    *) fail "Unknown MODE=$MODE; use reality, ss, hy2, or both"; return 1 ;;
  esac
  : "${SERVER_IP:?SERVER_IP is required in every mode}"
  validate_host "$SERVER_IP" SERVER_IP || return 1
  CONFIG_DIR="${CONFIG_DIR:-/etc/sing-box}"
  CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/config.json}"
  LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"
  validate_host "$LISTEN_ADDR" LISTEN_ADDR || return 1
  NODE_NAME="${NODE_NAME:-$MODE-$(hostname)}"
  REALITY_DEST="${REALITY_DEST:-}"
  REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-}"
  REALITY_DEST_CANDIDATES="${REALITY_DEST_CANDIDATES:-addons.mozilla.org:443 www.libreoffice.org:443 www.videolan.org:443 www.debian.org:443 www.postgresql.org:443}"
  if [[ "$MODE" != hy2 ]]; then
    ACTUAL_LISTEN_PORT=$(normalize_port "${ACTUAL_LISTEN_PORT:-}") || return 1
    LISTEN_PORT=$(normalize_port "${LISTEN_PORT:-}") || return 1
  fi
  if [[ "$MODE" == hy2 || "$MODE" == both ]]; then
    HY2_LISTEN_PORT=$(normalize_port "${HY2_LISTEN_PORT:-${ACTUAL_LISTEN_PORT:-}}") || return 1
    HY2_SERVER_PORTS="${HY2_SERVER_PORTS:-${LISTEN_PORT:-}}"
    normalize_hy2_ports "$HY2_SERVER_PORTS" || return 1
    HY2_PORT_HOPPING_MODE=${HY2_PORT_HOPPING_MODE:-external}
    case "$HY2_PORT_HOPPING_MODE" in local|external) ;; *) fail 'HY2_PORT_HOPPING_MODE must be local or external'; return 1 ;; esac
    HY2_OBFS="${HY2_OBFS:-gecko}"
    case "$HY2_OBFS" in gecko|none|salamander) ;; *) fail 'HY2_OBFS must be gecko, none, or salamander'; return 1 ;; esac
    HY2_SNI="${HY2_SNI:-hy2.local}"
    [[ "$HY2_SNI" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || { fail 'HY2_SNI must be a DNS name without whitespace'; return 1; }
    HY2_HOP_INTERVAL="${HY2_HOP_INTERVAL:-30s}"
    # Exact duration validity and >0 are checked below by sing-box.
    [[ "$HY2_HOP_INTERVAL" =~ ^[0-9a-z.µμ]+$ && "$HY2_HOP_INTERVAL" =~ [1-9] ]] || { fail 'HY2_HOP_INTERVAL must be a positive duration, e.g. 30s'; return 1; }
  fi
  BIN="${BIN:-$(command -v sing-box || true)}"
  # Generated client profiles use 1.12+ DNS/route syntax.
  MIN_CORE_VERSION="${MIN_CORE_VERSION:-1.12.0}"
  [[ "$MIN_CORE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { fail 'MIN_CORE_VERSION must look like 1.12.0'; return 1; }
  SSH_DIR="${SSH_DIR:-/root/.ssh}"
}

install_packages() {
  if _cmd apk; then apk add --no-cache "$@"
  elif _cmd apt-get; then apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  elif _cmd dnf; then dnf install -y "$@"
  elif _cmd yum; then yum install -y "$@"
  elif _cmd zypper; then zypper --non-interactive install "$@"
  elif _cmd pacman; then pacman -Sy --noconfirm "$@"
  else fail "Install required packages manually: $*"; fi
}

robust_download() {
  local url="$1" out="$2" attempt
  for attempt in 1 2 3 4 5; do
    if curl -fL -C - --retry 3 --retry-delay 2 --connect-timeout 20 -o "$out" "$url"; then return 0; fi
    _warn2 "Download interrupted; retry $attempt/5"
    sleep 2
  done
  return 1
}

core_version_ge() {
  # True when version $1 >= $2 (numeric X.Y.Z comparison; suffixes ignored).
  awk -v a="$1" -v b="$2" 'BEGIN{
    split(a,x,"."); split(b,y,".");
    for (i=1;i<=3;i++) { if ((x[i]+0) > (y[i]+0)) exit 0; if ((x[i]+0) < (y[i]+0)) exit 1 }
    exit 0 }'
}

latest_core_version() {
  local v
  # Unauthenticated API on a shared/NAT address is easily rate limited.
  v=$(curl -fsSL --connect-timeout 10 -m 20 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null |
        jq -er '.tag_name | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) | ltrimstr("v")' 2>/dev/null) &&
    { printf '%s\n' "$v"; return 0; }
  # Fall back to the redirect target of the releases/latest page.
  v=$(curl -fsSI --connect-timeout 10 -m 20 https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null |
        tr -d '\r' | awk 'tolower($0) ~ /^location: / {print $NF; exit}')
  v=${v#v}
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  printf '%s\n' "$v"
}

install_singbox() {
  local arch version tmp tarball binfile have
  if [[ -n "${BIN:-}" ]] && "$BIN" version >/dev/null 2>&1; then
    have=$("$BIN" version | awk '/^sing-box version/ {print $3; exit}')
    if [[ -n "$have" ]] && core_version_ge "$have" "$MIN_CORE_VERSION"; then
      _ok2 "Keeping installed core: $("$BIN" version | head -n1)"
      return 0
    fi
    # The generated client profiles use 1.12+ syntax; keeping an older core
    # would only fail later in prepare_outputs.
    _info2 "Installed core ${have:-unknown} is older than $MIN_CORE_VERSION; installing a current build."
  fi
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;;
    i?86) arch=386 ;; armv7l|armv6l|armhf) arch=armv7 ;;
    riscv64|s390x) arch=$(uname -m) ;; *) fail 'Unsupported architecture'; return 1 ;;
  esac
  version=$(latest_core_version) || { fail 'Cannot determine the latest sing-box release (network failure or GitHub API rate limit); retry later'; return 1; }
  mkdir -p /var/tmp
  tmp=$(mktemp -d /var/tmp/singbox-install.XXXXXX) || return 1
  tarball="sing-box-$version-linux-$arch-musl.tar.gz"
  if ! robust_download "https://github.com/SagerNet/sing-box/releases/download/v$version/$tarball" "$tmp/$tarball"; then
    tarball="sing-box-$version-linux-$arch.tar.gz"
    robust_download "https://github.com/SagerNet/sing-box/releases/download/v$version/$tarball" "$tmp/$tarball" || { rm -rf "$tmp"; return 1; }
  fi
  gzip -t "$tmp/$tarball" && tar -xzf "$tmp/$tarball" -C "$tmp" || { rm -rf "$tmp"; return 1; }
  binfile=$(find "$tmp" -type f -name sing-box -print -quit)
  [[ -n "$binfile" ]] && "$binfile" version >/dev/null || { rm -rf "$tmp"; return 1; }
  mkdir -p /usr/local/bin
  # Write beside the target and rename: overwriting a running binary gives ETXTBSY.
  install -m 755 "$binfile" /usr/local/bin/.sing-box.new && cmp -s "$binfile" /usr/local/bin/.sing-box.new &&
    mv -f /usr/local/bin/.sing-box.new /usr/local/bin/sing-box || { rm -f /usr/local/bin/.sing-box.new; rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  BIN=/usr/local/bin/sing-box
}

reality_dest_probe() {
  local host="${1%:*}" port="${1##*:}" line
  local -a opts=(--tlsv1.3 --tls-max 1.3)
  if curl --http2 -V >/dev/null 2>&1; then opts+=(--http2); fi
  line=$(curl -sI "${opts[@]}" --connect-timeout 4 -m 8 "https://$host:$port/" 2>/dev/null) || return 1
  [[ "$line" == HTTP/* ]]
}

select_reality_dest() {
  local cand host port
  if [[ -z "$REALITY_DEST" && -n "$REALITY_SERVER_NAME" ]]; then REALITY_DEST="$REALITY_SERVER_NAME:443"; fi
  if [[ -z "$REALITY_DEST" ]]; then
    for cand in $REALITY_DEST_CANDIDATES; do
      [[ "$cand" == *:* ]] || cand="$cand:443"
      if reality_dest_probe "$cand"; then REALITY_DEST="$cand"; break; fi
    done
    [[ -n "$REALITY_DEST" ]] || { fail 'No reachable TLS 1.3 Reality target; set REALITY_DEST explicitly'; return 1; }
  else
    [[ "$REALITY_DEST" == *:* ]] || REALITY_DEST="$REALITY_DEST:443"
    reality_dest_probe "$REALITY_DEST" || _warn2 "Target probe failed for explicit REALITY_DEST=$REALITY_DEST; handshake self-check must still pass."
  fi
  host="${REALITY_DEST%:*}"; host="${host#[}"; host="${host%]}"
  validate_host "$host" REALITY_DEST || return 1
  port=$(normalize_port "${REALITY_DEST##*:}") || return 1
  REALITY_DEST_HOST="$host"; REALITY_DEST_PORT="$port"
  REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-$host}"
  validate_host "$REALITY_SERVER_NAME" REALITY_SERVER_NAME || return 1
}

generate_credentials() {
  local keys
  keys=$("$BIN" generate reality-keypair) || return 1
  PRIVATE_KEY=$(printf '%s\n' "$keys" | awk '/^PrivateKey:/{print $2}')
  PUBLIC_KEY=$(printf '%s\n' "$keys" | awk '/^PublicKey:/{print $2}')
  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || { fail 'Cannot parse Reality keypair'; return 1; }
  UUID=$("$BIN" generate uuid) || return 1
  SHORT_ID=$("$BIN" generate rand 8 --hex) || return 1
}

generate_ss_credentials() {
  SS_METHOD="${SS_METHOD:-aes-128-gcm}"
  SS_PASSWORD="${SS_PASSWORD:-$("$BIN" generate rand 16 --base64)}"
  [[ -n "$SS_PASSWORD" ]] || return 1
}

cert_matches_sni() {
  # sing-box emits a self-signed leaf, which can never pass `openssl verify`;
  # match the requested name against SAN (preferred) or the subject CN instead.
  local cert="$1" sans
  if sans=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null) && [[ -n "$sans" ]]; then
    printf '%s\n' "$sans" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -qxF "DNS:$HY2_SNI"
    return $?
  fi
  # OpenSSL < 1.1.1 has no -ext; fall back to an exact commonName match.
  openssl x509 -in "$cert" -noout -subject -nameopt multiline 2>/dev/null |
    sed -n 's/^[[:space:]]*commonName[[:space:]]*=[[:space:]]*//p' | grep -qxF "$HY2_SNI"
}

valid_tls_pair() {
  local cert="$1" key="$2"
  [[ -s "$cert" && -s "$key" ]] || return 1
  openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null 2>&1 || return 1
  cert_matches_sni "$cert" || return 1
  cmp -s <(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null) <(openssl pkey -in "$key" -pubout 2>/dev/null) || return 1
  openssl pkey -in "$key" -noout >/dev/null 2>&1
}

prepare_hy2_tls() {
  # Separate installer-owned directories; never overwrite unrelated certificates.
  local id base fresh pem
  id=$(printf '%s' "$HY2_SNI" | cksum | awk '{print $1}')
  base="$CONFIG_DIR/hy2-tls/$id"
  mkdir -p "$CONFIG_DIR/hy2-tls"
  chmod 700 "$CONFIG_DIR/hy2-tls"
  if valid_tls_pair "$base/cert.pem" "$base/key.pem"; then
    HY2_CERT="$base/cert.pem"; HY2_KEY="$base/key.pem"
    chmod 700 "$base"; chmod 600 "$HY2_CERT" "$HY2_KEY"
    _info2 'Reusing TLS pair after expiry, hostname, chain and key-match checks.'
    return 0
  fi
  fresh=$(mktemp -d "$CONFIG_DIR/hy2-tls/$id.XXXXXX") || return 1
  chmod 700 "$fresh"
  pem=$("$BIN" generate tls-keypair "$HY2_SNI" -m 36) || return 1
  # Accept optional labels/CRLF but only complete, single PEM blocks.
  printf '%s\n' "$pem" | tr -d '\r' | awk '
    /^-----BEGIN CERTIFICATE-----$/ {n++; copying=1}
    copying {print}
    /^-----END CERTIFICATE-----$/ {copying=0; ends++}
    END {if (n!=1 || ends!=1 || copying) exit 1}
  ' > "$fresh/cert.pem" || return 1
  printf '%s\n' "$pem" | tr -d '\r' | awk '
    /^-----BEGIN (RSA |EC )?PRIVATE KEY-----$/ {n++; copying=1}
    copying {print}
    /^-----END (RSA |EC )?PRIVATE KEY-----$/ {copying=0; ends++}
    END {if (n!=1 || ends!=1 || copying) exit 1}
  ' > "$fresh/key.pem" || return 1
  chmod 600 "$fresh/cert.pem" "$fresh/key.pem"
  valid_tls_pair "$fresh/cert.pem" "$fresh/key.pem" || { fail 'Generated TLS pair failed OpenSSL checks'; return 1; }
  # Retain any invalid/older pair for inspection, including rollback references.
  if [[ ! -e "$base" ]]; then mv "$fresh" "$base"; fresh="$base"; fi
  HY2_CERT="$fresh/cert.pem"; HY2_KEY="$fresh/key.pem"
}

generate_hy2_credentials() {
  HY2_PASSWORD="${HY2_PASSWORD:-$("$BIN" generate rand 32 --hex)}"
  HY2_OBFS_PASSWORD="${HY2_OBFS_PASSWORD:-$("$BIN" generate rand 32 --hex)}"
  [[ -n "$HY2_PASSWORD" && -n "$HY2_OBFS_PASSWORD" ]] || return 1
  prepare_hy2_tls
}

build_nodes() {
  local rin rout sin sout hin hout
  NEW_INBOUNDS='[]'; CLIENT_OUTBOUNDS='[]'
  if [[ "$MODE" == reality || "$MODE" == both ]]; then
    rin=$(jq -cn --arg addr "$LISTEN_ADDR" --argjson port "$ACTUAL_LISTEN_PORT" --arg uuid "$UUID" --arg sni "$REALITY_SERVER_NAME" --arg dest "$REALITY_DEST_HOST" --argjson dp "$REALITY_DEST_PORT" --arg key "$PRIVATE_KEY" --arg sid "$SHORT_ID" '
      {type:"vless",tag:"reality-in",listen:$addr,listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$dest,server_port:$dp},private_key:$key,short_id:[$sid]}}}') || return 1
    rout=$(jq -cn --arg ip "$SERVER_IP" --argjson port "$LISTEN_PORT" --arg uuid "$UUID" --arg sni "$REALITY_SERVER_NAME" --arg key "$PUBLIC_KEY" --arg sid "$SHORT_ID" '
      {type:"vless",tag:"reality-out",server:$ip,server_port:$port,uuid:$uuid,flow:"xtls-rprx-vision",tls:{enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:"chrome"},reality:{enabled:true,public_key:$key,short_id:$sid}}}') || return 1
    NEW_INBOUNDS=$(jq -cn --argjson n "$rin" '[$n]')
    CLIENT_OUTBOUNDS=$(jq -cn --argjson n "$rout" '[$n]')
  fi
  if [[ "$MODE" == ss ]]; then
    sin=$(jq -cn --arg addr "$LISTEN_ADDR" --argjson p "$ACTUAL_LISTEN_PORT" --arg m "$SS_METHOD" --arg pw "$SS_PASSWORD" '{type:"shadowsocks",tag:"ss-in",listen:$addr,listen_port:$p,method:$m,password:$pw}') || return 1
    sout=$(jq -cn --arg ip "$SERVER_IP" --argjson p "$LISTEN_PORT" --arg m "$SS_METHOD" --arg pw "$SS_PASSWORD" '{type:"shadowsocks",tag:"ss-out",server:$ip,server_port:$p,method:$m,password:$pw}') || return 1
    NEW_INBOUNDS=$(jq -cn --argjson n "$sin" '[$n]')
    CLIENT_OUTBOUNDS=$(jq -cn --argjson n "$sout" '[$n]')
  fi
  if [[ "$MODE" == hy2 || "$MODE" == both ]]; then
    hin=$(jq -cn --arg addr "$LISTEN_ADDR" --argjson p "$HY2_LISTEN_PORT" --arg pw "$HY2_PASSWORD" --arg obfs "$HY2_OBFS" --arg opw "$HY2_OBFS_PASSWORD" --arg sni "$HY2_SNI" --arg cert "$HY2_CERT" --arg key "$HY2_KEY" '
      {type:"hysteria2",tag:"hy2-in",listen:$addr,listen_port:$p,users:[{name:"mobile",password:$pw}],ignore_client_bandwidth:true,tls:{enabled:true,server_name:$sni,alpn:["h3"],certificate_path:$cert,key_path:$key}}
      + (if $obfs=="none" then {} else {obfs:{type:$obfs,password:$opw}} end)') || return 1
    hout=$(jq -cn --arg ip "$SERVER_IP" --argjson ports "$HY2_PORTS_JSON" --argjson count "$HY2_PORT_COUNT" --argjson single "$HY2_SINGLE_PORT" --arg hop "$HY2_HOP_INTERVAL" --arg pw "$HY2_PASSWORD" --arg obfs "$HY2_OBFS" --arg opw "$HY2_OBFS_PASSWORD" --arg sni "$HY2_SNI" --rawfile cert "$HY2_CERT" '
      {type:"hysteria2",tag:"hy2-out",server:$ip,password:$pw,tls:{enabled:true,server_name:$sni,alpn:["h3"],certificate:[$cert]}}
      + (if $count==1 then {server_port:$single} else {server_ports:$ports,hop_interval:$hop} end)
      + (if $obfs=="none" then {} else {obfs:{type:$obfs,password:$opw}} end)') || return 1
    NEW_INBOUNDS=$(jq -cn --argjson a "$NEW_INBOUNDS" --argjson n "$hin" '$a+[$n]')
    CLIENT_OUTBOUNDS=$(jq -cn --argjson a "$CLIENT_OUTBOUNDS" --argjson n "$hout" '$a+[$n]')
  fi
}

probe_hy2_support() {
  [[ "$MODE" == hy2 || "$MODE" == both ]] || return 0
  local probe="$WORK_DIR/hy2-feature.json"
  # This parses both inbound and client fields with the installed executable.
  # A check failure (including missing with_quic) never triggers core replacement.
  jq -n --argjson ins "$NEW_INBOUNDS" --argjson outs "$CLIENT_OUTBOUNDS" '{inbounds:[$ins[]|select(.type=="hysteria2")],outbounds:[$outs[]|select(.type=="hysteria2")]}' > "$probe" || return 1
  if ! "$BIN" check -c "$probe"; then
    fail "HY2 $HY2_OBFS configuration probe failed; inspect the core's diagnostics (QUIC/obfs support, certificate or config errors). Gecko needs a supporting core, normally >=1.14 with with_quic. No core replacement was attempted."
    return 1
  fi
  # Probe the duration even for a single advertised port, where no hop is emitted.
  jq --arg hop "$HY2_HOP_INTERVAL" '.outbounds[0] |= (del(.server_port) + {server_ports:["443:444"],hop_interval:$hop})' "$probe" > "$WORK_DIR/hop-check.json" || return 1
  "$BIN" check -c "$WORK_DIR/hop-check.json" || { fail 'HY2_HOP_INTERVAL rejected by sing-box'; return 1; }
  # Core currently accepts some nonpositive durations at parse time; Go duration
  # syntax is validated above, then this numeric check enforces a positive value.
  [[ "$HY2_HOP_INTERVAL" != -* && "$HY2_HOP_INTERVAL" =~ [1-9] ]] || return 1
}

validate_existing_config() {
  [[ ! -e "$CONFIG_FILE" ]] && return 0
  jq -e -s 'length==1 and (.[0] | type=="object" and ((has("inbounds")|not) or (.inbounds|type=="array")) and ((.inbounds // []) | all(.[]; type=="object")))' "$CONFIG_FILE" >/dev/null || {
    fail "Malformed existing config; refusing to overwrite $CONFIG_FILE"; return 1;
  }
}

merge_candidate() {
  # $1 = array of ALL selected inbounds; one merge for both, never two writes.
  local nodes="$1" target="$2"
  jq -e 'type=="array" and length>0 and all(.[];type=="object")' <<< "$nodes" >/dev/null || return 1
  validate_existing_config || return 1
  if [[ -e "$CONFIG_FILE" ]]; then
    jq --argjson nodes "$nodes" '.inbounds = (((.inbounds // []) | map(select(.tag=="argo-in" or (.type=="vless" and .transport.type=="ws")))) + $nodes)' "$CONFIG_FILE" > "$target" || return 1
  else
    jq -n --argjson nodes "$nodes" '{log:{level:"warn",output:"/var/log/sing-box.log",timestamp:true},inbounds:$nodes,outbounds:[{type:"direct",tag:"direct"}]}' > "$target" || return 1
  fi
  chmod 600 "$target"
  "$BIN" check -c "$target"
}

commit_candidate() {
  local candidate="$1"
  CONFIG_BACKUP=''; CONFIG_WAS_PRESENT=0
  if [[ -e "$CONFIG_FILE" ]]; then
    CONFIG_WAS_PRESENT=1
    CONFIG_BACKUP=$(mktemp "$CONFIG_FILE.bak.XXXXXX") || return 1
    cp -p "$CONFIG_FILE" "$CONFIG_BACKUP" || return 1
    chmod 600 "$CONFIG_BACKUP"
  fi
  mv -f "$candidate" "$CONFIG_FILE" || return 1
  CONFIG_COMMITTED=1
}

restart_service() {
  if _cmd systemctl && [[ -d /run/systemd/system ]]; then
    systemctl restart sing-box && sleep 2 && systemctl is-active --quiet sing-box
  elif _cmd rc-service; then
    rc-service sing-box restart && rc-service sing-box status
  else fail 'Neither systemd nor OpenRC is available'; fi
}

start_service() {
  local bin_path="$BIN"
  if [[ "${HY2_RC_DEP:-}" == hy2-hop ]]; then
    # OpenRC dependency is HY2-only; non-HY2 installs retain the original unit.
    local hy2_need='need net hy2-hop;'
    local hy2_pre='start_pre() { /usr/local/sbin/hy2-hop restore; }'
  else local hy2_need='need net;' hy2_pre=''; fi
  if _cmd systemctl && [[ -d /run/systemd/system ]]; then
    mkdir -p /etc/systemd/system || return 1
    # Keep a one-time copy of a unit we did not create instead of eating it.
    if [[ -f /etc/systemd/system/sing-box.service && ! -e /etc/systemd/system/sing-box.service.pre-installer ]]; then
      cp -p /etc/systemd/system/sing-box.service /etc/systemd/system/sing-box.service.pre-installer || return 1
      _info2 'Existing sing-box unit backed up to sing-box.service.pre-installer'
    fi
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target
[Service]
ExecStart=$bin_path run -c $CONFIG_FILE
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable sing-box || return 1
  else
    if _cmd apk && ! _cmd rc-service; then apk add --no-cache openrc || return 1; fi
    _cmd rc-service || { fail 'OpenRC unavailable'; return 1; }
    mkdir -p /etc/init.d || return 1
    cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
name="sing-box"
description="sing-box proxy service"
command="$bin_path"
command_args="run -c $CONFIG_FILE"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
depend() { $hy2_need }
$hy2_pre
EOF
    chmod 755 /etc/init.d/sing-box && rc-update add sing-box default || return 1
  fi
  restart_service
}

rollback_config() {
  [[ "${CONFIG_COMMITTED:-0}" == 1 ]] || return 0
  if [[ "$CONFIG_WAS_PRESENT" == 1 ]]; then
    local restore
    restore=$(mktemp "$CONFIG_DIR/.rollback.XXXXXX") || return 1
    cp -p "$CONFIG_BACKUP" "$restore" && mv -f "$restore" "$CONFIG_FILE" || return 1
    _warn2 "Restored previous config from $CONFIG_BACKUP"
    restart_service || _warn2 'Previous config restored but service recovery failed; inspect service logs.'
  else
    rm -f "$CONFIG_FILE"
    if _cmd systemctl && [[ -d /run/systemd/system ]]; then systemctl stop sing-box || true
    elif _cmd rc-service; then rc-service sing-box stop || true; fi
  fi
  CONFIG_COMMITTED=0
}

check_and_open_firewall() {
  local rules='' rule port proto
  case "$MODE" in
    reality|both) rules="$ACTUAL_LISTEN_PORT/tcp" ;;
    ss) rules="$ACTUAL_LISTEN_PORT/tcp $ACTUAL_LISTEN_PORT/udp" ;;
  esac
  if [[ "$MODE" == hy2 || "$MODE" == both ]]; then rules="$rules $HY2_LISTEN_PORT/udp"; fi
  for rule in $rules; do
    port="${rule%/*}"; proto="${rule#*/}"
    if _cmd ufw; then
      local status
      status=$(ufw status) || return 1
      if [[ "$status" == *'Status: active'* ]]; then ufw allow "$port/$proto" || return 1; fi
    fi
    if _cmd firewall-cmd; then
      if firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="$port/$proto" && firewall-cmd --add-port="$port/$proto" || return 1
      fi
    fi
  done
  _info2 'Opened selected INTERNAL listener ports only. Provider security groups and NAT must be configured separately.'
}

setup_logrotate() {
  if ! _cmd logrotate; then install_packages logrotate || { _warn2 'logrotate installation failed'; return 1; }; fi
  mkdir -p /etc/logrotate.d
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
  if _cmd apk; then
    mkdir -p /etc/periodic/daily
    cat > /etc/periodic/daily/logrotate <<'EOF'
#!/bin/sh
/usr/sbin/logrotate /etc/logrotate.conf
EOF
    chmod 755 /etc/periodic/daily/logrotate
    rc-service crond start || _warn2 'Enable crond to schedule log rotation.'
  fi
}

full_client_config() {
  # $1 = selected outbound array, $2 = destination. Same mobile TUN/DNS/route
  # layout as the known working profile. PROXY defaults to Reality in both.
  jq -n --argjson nodes "$1" '
    ($nodes | map(.tag)) as $tags |
    {log:{level:"warn",timestamp:true},
     dns:{servers:[{type:"https",tag:"remote-dns",server:"1.1.1.1",server_port:443,path:"/dns-query",detour:"PROXY"}],final:"remote-dns",strategy:"ipv4_only"},
     inbounds:[{type:"tun",tag:"tun-in",interface_name:"tun0",address:["172.19.0.1/30"],mtu:1400,auto_route:true,strict_route:true,stack:"system"}],
     outbounds:([{type:"selector",tag:"PROXY",outbounds:$tags,default:$tags[0]}]+$nodes),
     route:{rules:[{protocol:"dns",action:"hijack-dns"},{port:53,action:"hijack-dns"}],final:"PROXY",auto_detect_interface:true}}
  ' > "$2"
}

prepare_outputs() {
  local tag single name
  mkdir -p "$WORK_DIR/outputs"
  printf '%s\n' "$CLIENT_OUTBOUNDS" | jq . > "$WORK_DIR/outputs/client-outbounds.json"
  full_client_config "$CLIENT_OUTBOUNDS" "$WORK_DIR/outputs/client.json" || return 1
  for tag in reality ss hy2; do
    single=$(jq -c --arg tag "$tag-out" '[.[]|select(.tag==$tag)]' <<< "$CLIENT_OUTBOUNDS") || return 1
    if [[ "$single" != '[]' ]]; then full_client_config "$single" "$WORK_DIR/outputs/client-$tag.json" || return 1; fi
  done
  for name in "$WORK_DIR"/outputs/client.json "$WORK_DIR"/outputs/client-reality.json "$WORK_DIR"/outputs/client-ss.json "$WORK_DIR"/outputs/client-hy2.json; do
    [[ -f "$name" ]] || continue
    "$BIN" check -c "$name" || return 1
    chmod 600 "$name"
  done
  # client-outbounds.json is deliberately an array, not a runnable root config.
  jq -n --argjson nodes "$CLIENT_OUTBOUNDS" '{outbounds:$nodes}' > "$WORK_DIR/outbounds-check.json" || return 1
  "$BIN" check -c "$WORK_DIR/outbounds-check.json" || return 1
  chmod 600 "$WORK_DIR/outputs/client-outbounds.json"
  render_node_output > "$WORK_DIR/outputs/node_output.txt" || return 1
  chmod 600 "$WORK_DIR/outputs/node_output.txt"
}

uri_escape() { jq -rn --arg s "$1" '$s|@uri'; }

render_outbound_snippets() {
  jq --indent 2 '.[]' | sed 's/^/    /; s/^    }$/    },/'
}

render_node_output() {
  local host="$SERVER_IP" link name sni
  [[ "$host" != *:* ]] || host="[$host]"
  name=$(uri_escape "$NODE_NAME")
  printf 'Node: %s\nMode: %s\n' "$NODE_NAME" "$MODE"
  printf '%s\n' 'Rerun behavior: selected inbound credentials are regenerated; fixed SS_PASSWORD/HY2_PASSWORD/HY2_OBFS_PASSWORD overrides are retained. Other non-Argo inbounds are removed. Re-import the new client profile.'
  if [[ "$MODE" == reality || "$MODE" == both ]]; then
    sni=$(uri_escape "$REALITY_SERVER_NAME")
    link="vless://$UUID@$host:$LISTEN_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp#$name"
    printf '\nReality URI\n%s\n\nReality outbound JSON\n' "$link"
    jq '[.[]|select(.tag=="reality-out")]' <<< "$CLIENT_OUTBOUNDS" | render_outbound_snippets
    printf '\nClash / Mihomo YAML\n'
    # JSON quoted scalars are also valid YAML, including unusual node names.
    jq -r --arg name "$NODE_NAME" '.[]|select(.tag=="reality-out")| "- name: \($name|tojson)\n  type: vless\n  server: \(.server|tojson)\n  port: \(.server_port)\n  uuid: \(.uuid|tojson)\n  flow: xtls-rprx-vision\n  tls: true\n  servername: \(.tls.server_name|tojson)\n  client-fingerprint: chrome\n  reality-opts:\n    public-key: \(.tls.reality.public_key|tojson)\n    short-id: \(.tls.reality.short_id|tojson)\n  network: tcp"' <<< "$CLIENT_OUTBOUNDS"
  fi
  if [[ "$MODE" == ss ]]; then
    link="ss://$(printf '%s:%s' "$SS_METHOD" "$SS_PASSWORD" | base64 | tr -d '\r\n' | tr '+/' '-_' | tr -d '=')@$host:$LISTEN_PORT#$name"
    printf '\nShadowsocks URI\n%s\n' "$link"
  fi
  if [[ "$MODE" == hy2 || "$MODE" == both ]]; then
    printf '\nHY2 (%s): JSON is authoritative; no universal share URI is emitted.\n' "$HY2_OBFS"
    printf 'TLS SNI: %s; inline certificate trust, no insecure bypass.\n' "$HY2_SNI"
    printf 'Single internal UDP listener: %s. Public UDP ports: %s.\n' "$HY2_LISTEN_PORT" "$HY2_SERVER_PORTS"
    if [[ ${HY2_PORT_HOPPING_MODE:-external} == local ]]; then
      printf 'Local inet UDP redirect enabled for the advertised ranges only, to UDP %s. Open the ENTIRE UDP range in cloud security groups; no cloud settings changed.\n' "$HY2_LISTEN_PORT"
    else
      printf 'External NAT mode: map EVERY public UDP port to this host UDP %s. No local NAT created.\n' "$HY2_LISTEN_PORT"
    fi
  fi
  printf '\nFull mobile profile: %s/client.json\nPer-protocol full profiles: client-reality.json / client-ss.json / client-hy2.json (selected modes only).\nSelected outbound array: client-outbounds.json\n' "$CONFIG_DIR"
  printf '\nSelected client outbound snippets (remove the final comma if this is the last array item)\n'
  render_outbound_snippets <<< "$CLIENT_OUTBOUNDS"
  printf '\nSelf-check verifies local protocol handshake + HTTPS egress, not public NAT or UDP hopping.\n'
}

publish_outputs() {
  local file tag
  for file in "$WORK_DIR"/outputs/*; do install -m 600 "$file" "$CONFIG_DIR/${file##*/}" || return 1; done
  for tag in reality ss hy2; do
    if ! jq -e --arg tag "$tag-out" 'any(.[];.tag==$tag)' <<< "$CLIENT_OUTBOUNDS" >/dev/null; then rm -f "$CONFIG_DIR/client-$tag.json"; fi
  done
  cat "$CONFIG_DIR/node_output.txt"
}

self_check_node() (
  # Subshell EXIT trap guarantees private temporary files and client cleanup.
  local node="$1" tag port listener target conf log pid='' i code='' ready=0
  tag=$(jq -r '.tag' <<< "$node")
  port=$((20000 + RANDOM % 30000))
  listener="$ACTUAL_LISTEN_PORT"
  [[ "$tag" != hy2-out ]] || listener="$HY2_LISTEN_PORT"
  target="$LISTEN_ADDR"
  case "$target" in 0.0.0.0) target=127.0.0.1 ;; ::) target=::1 ;; esac
  conf=$(mktemp "$WORK_DIR/selfcheck.XXXXXX") || exit 1
  log="$conf.log"
  trap 'if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; rm -f "$conf" "$log"' EXIT
  jq -n --argjson node "$node" --arg target "$target" --argjson listener "$listener" --argjson port "$port" '
    {log:{level:"warn"},inbounds:[{type:"socks",listen:"127.0.0.1",listen_port:$port}],outbounds:[($node|del(.server_ports,.hop_interval)|.server=$target|.server_port=$listener)],route:{final:$node.tag}}' > "$conf" || exit 1
  "$BIN" check -c "$conf" || exit 1
  "$BIN" run -c "$conf" > "$log" 2>&1 & pid=$!
  for ((i=0; i<12; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then ready=1; break; fi
    sleep 1
  done
  if [[ "$ready" == 1 ]]; then
    for target in https://www.google.com/generate_204 https://cloudflare.com/cdn-cgi/trace https://www.baidu.com/favicon.ico; do
      code=$(curl --noproxy '' -sS --connect-timeout 5 -m 15 -x "socks5h://127.0.0.1:$port" -o /dev/null -w '%{http_code}' "$target") || code=''
      if [[ "$code" == 200 || "$code" == 204 ]]; then _ok2 "$tag handshake + HTTPS egress passed"; exit 0; fi
    done
  fi
  _err2 "$tag self-check failed; temporary client log follows"
  cat "$log" >&2
  exit 1
)

self_check() {
  local node
  while IFS= read -r node; do self_check_node "$node" || return 1; done < <(jq -c '.[]' <<< "$CLIENT_OUTBOUNDS")
}

setup_ssh_key() {
  local key="$SSH_DIR/id_ed25519" pub="$SSH_DIR/id_ed25519.pub" auth="$SSH_DIR/authorized_keys" fresh backup derived public_line
  mkdir -p "$SSH_DIR" || return 1
  chmod 700 "$SSH_DIR" || return 1
  if ! _cmd ssh-keygen; then
    _warn2 'ssh-keygen unavailable; preserving all SSH files unchanged.'
    return 0
  fi
  if [[ "${SSH_KEY_REGENERATE:-0}" == 1 ]]; then
    backup=$(mktemp -d "$SSH_DIR/key-backup.XXXXXX") || return 1
    chmod 700 "$backup"
    [[ ! -e "$key" ]] || cp -p "$key" "$backup/id_ed25519" || return 1
    [[ ! -e "$pub" ]] || cp -p "$pub" "$backup/id_ed25519.pub" || return 1
    fresh=$(mktemp -d "$SSH_DIR/new-key.XXXXXX") || return 1
    ssh-keygen -q -t ed25519 -f "$fresh/id_ed25519" -N '' -C "root@$(hostname)" || { rm -rf "$fresh"; return 1; }
    mv -f "$fresh/id_ed25519" "$key" && mv -f "$fresh/id_ed25519.pub" "$pub" || return 1
    rmdir "$fresh"
    _info2 "Old SSH key files backed up in $backup; all authorized_keys entries retained."
  elif [[ -e "$key" && ! -e "$pub" ]]; then
    # Never overwrite/delete a standalone private key, including encrypted keys.
    derived=$(ssh-keygen -y -P '' -f "$key" </dev/null 2>/dev/null) || {
      _warn2 'Cannot derive public key (possibly encrypted); existing private key preserved.'; return 0;
    }
    printf '%s\n' "$derived" > "$pub" || return 1
  elif [[ ! -e "$key" && ! -e "$pub" ]]; then
    ssh-keygen -q -t ed25519 -f "$key" -N '' -C "root@$(hostname)" || return 1
  fi
  if [[ -s "$pub" ]]; then
    public_line=$(cat "$pub")
    if ! grep -qxF "$public_line" "$auth" 2>/dev/null; then
      # Ensure a previous unterminated line cannot absorb the appended key.
      [[ ! -s "$auth" ]] || printf '\n' >> "$auth"
      printf '%s\n' "$public_line" >> "$auth" || return 1
    fi
    chmod 600 "$pub" "$auth" || return 1
  fi
  if [[ -f "$key" ]]; then
    chmod 600 "$key" || return 1
    if [[ "${SSH_KEY_DELETE:-0}" == 1 ]]; then
      cat "$key" && rm -f "$key" || return 1
      _warn2 'Private key displayed and removed by explicit SSH_KEY_DELETE=1.'
    else _info2 "SSH key preserved: $key. Use sshkey to view; sshkey --delete explicitly removes only that private key."; fi
  fi
}

setup_alias() {
  cat > /usr/local/bin/closepwd <<'CLOSEPWD'
#!/bin/bash
# Explicit opt-in only. Keep the current SSH session open throughout.
set -euo pipefail
[[ $(id -u) == 0 ]] || { echo 'Run closepwd as root.' >&2; exit 1; }
conf=/etc/ssh/sshd_config
[[ -f "$conf" && ! -L "$conf" ]] || { echo 'Missing or symlinked sshd_config; refusing changes.' >&2; exit 1; }
command -v sshd >/dev/null || { echo 'sshd not found.' >&2; exit 1; }
sshd -t -f "$conf" || exit 1
# sshd -T -C evaluates Match for the actual SSH connection. Refuse all
# configured Match blocks (including Includes) rather than claiming that a
# global setting closes password access for every user/address.
debug=$(sshd -T -ddd -f "$conf" 2>&1) || { echo 'Cannot inspect SSH configuration.' >&2; exit 1; }
if grep -Eiq 'checking (syntax for .match|match for)' <<< "$debug"; then
  echo 'SSH configuration contains Match rules; refusing automatic modification. Review all included files manually.' >&2
  exit 1
fi
effective=$(sshd -T -f "$conf") || exit 1
[[ $(awk '$1=="pubkeyauthentication" {print $2; exit}' <<< "$effective") == yes ]] || { echo 'Public key authentication is not enabled; refusing.' >&2; exit 1; }
echo 'Only continue after independently verifying a NEW SSH login with your private key.'
echo 'Keep this session open. This changes SSH authentication for the server.'
read -r -p 'Type CLOSE to continue: ' confirm
[[ "$confirm" == CLOSE ]] || { echo 'Cancelled; no changes made.'; exit 1; }
backup=$(mktemp -d /etc/ssh/closepwd-backup.XXXXXX)
chmod 700 "$backup"
cp -p "$conf" "$backup/sshd_config"
tmp=$(mktemp /etc/ssh/.closepwd.XXXXXX)
restart_ssh() {
  if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
    systemctl restart ssh || systemctl restart sshd
  elif command -v rc-service >/dev/null; then rc-service sshd restart || rc-service ssh restart
  elif command -v service >/dev/null; then service ssh restart || service sshd restart
  else return 1; fi
}
rollback() {
  echo "Failed; restoring SSH configuration from $backup. Keep this session open." >&2
  cp -p "$backup/sshd_config" "$conf" || { echo 'CRITICAL: restore failed; repair SSH manually.' >&2; return 1; }
  sshd -t -f "$conf" && restart_ssh || { echo 'CRITICAL: could not verify or restart restored SSH; repair manually.' >&2; return 1; }
}
# Put global settings first, before any Include or Match. Preserve existing content.
{ printf '%s\n' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no'; cat "$conf"; } > "$tmp"
if ! cat "$tmp" > "$conf"; then rm -f "$tmp"; rollback || true; exit 1; fi
rm -f "$tmp"
if ! sshd -t -f "$conf"; then rollback || true; exit 1; fi
effective=$(sshd -T -f "$conf") || { rollback || true; exit 1; }
if [[ $(awk '$1=="passwordauthentication" {print $2; exit}' <<< "$effective") != no || $(awk '$1=="kbdinteractiveauthentication" {print $2; exit}' <<< "$effective") != no || $(awk '$1=="pubkeyauthentication" {print $2; exit}' <<< "$effective") != yes ]]; then
  echo 'Effective global SSH settings failed verification.' >&2; rollback || true; exit 1
fi
if ! restart_ssh; then rollback || true; exit 1; fi
echo "SSH restarted; backup: $backup/sshd_config"
echo 'Global defaults verified. Match blocks may override them: verify your actual connection with sshd -T -C and test a new login before closing this session.'
CLOSEPWD
  chmod 700 /usr/local/bin/closepwd
  cat > /usr/local/bin/sshkey <<'EOF'
#!/bin/sh
KEY=/root/.ssh/id_ed25519
[ -f "$KEY" ] || { printf '%s\n' 'No retained private key.'; exit 0; }
cat "$KEY" || exit 1
case "${1:-}" in
  --delete) rm -f "$KEY" ;;
  '') printf '%s\n' 'Private key retained. After saving it, sshkey --delete explicitly removes this private key only.' ;;
  *) printf '%s\n' 'Usage: sshkey [--delete]' >&2; exit 1 ;;
esac
EOF
  chmod 755 /usr/local/bin/sshkey
  local rc line
  for rc in "$HOME/.bashrc" "$HOME/.profile"; do
    touch "$rc"
    for line in "alias shownode='cat $CONFIG_DIR/node_output.txt'" "alias sshkey='sh /usr/local/bin/sshkey'" "alias showsshkey='sh /usr/local/bin/sshkey'" "alias log='tail -n 100 /var/log/sing-box.log'"; do
      grep -qxF "$line" "$rc" || printf '%s\n' "$line" >> "$rc"
    done
  done
}

# Local hopping uses nftables only; never changes host traffic queues.
hy2_hop_prepare() {
  HY2_HOP_ACTIVE=0
  # Old network state must be reviewed explicitly; never delete host queues.
  if [[ -e /etc/hy2-limit/state.json || -e /run/hy2-limit-live.json || -e /etc/systemd/system/sing-box.service.d/hy2-limit.conf ]]; then
    fail 'Legacy networking integration detected; restore/review the previous installation before retrying. No host queues changed.'; return 1
  fi
  if [[ "$MODE" != hy2 && "$MODE" != both ]] || [[ "$HY2_PORT_HOPPING_MODE" != local ]]; then
    if [[ -e /etc/hy2-hop/state.json ]]; then fail 'Existing local forwarding must be reviewed before changing mode; no network rules changed'; return 1; fi
    return 0
  fi
  _cmd nft || install_packages nftables
  _cmd ip || install_packages iproute2
  _cmd flock || install_packages util-linux
  if _cmd systemctl && [[ -d /run/systemd/system ]]; then HY2_HOP_INIT=systemd
  elif _cmd rc-service && _cmd rc-update; then HY2_HOP_INIT=openrc
  else fail 'Local hopping requires systemd or OpenRC'; return 1; fi
  HY2_HOP_ACTIVE=1
}

hy2_hop_install() {
  [[ "${HY2_HOP_ACTIVE:-0}" == 1 ]] || return 0
  cat > "$WORK_DIR/hy2-hop" <<'HY2_HOP_HELPER'
#!/bin/bash
set -euo pipefail
umask 077
D=/etc/hy2-hop
STATE=$D/state.json
NAT_STATE=$D/nat.json
TABLE=hy2_hopping
err() { printf '[hy2-hop] %s\n' "$*" >&2; return 1; }
iface_valid() { [[ "$1" =~ ^[a-zA-Z0-9_.:-]{1,15}$ && "$1" != lo && "$1" != -* ]]; }
secure() { [[ ! -L "$1" && $(stat -c %u "$1") == 0 && $(stat -c %a "$1") == "$2" ]]; }
put() { local tmp; tmp=$(mktemp "$D/.write.XXXXXX") || return 1; printf '%s\n' "$2" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$1"; }
intervals() {
  jq -ce '
    def port: type=="number" and floor==. and .>=1 and .<=65535;
    if type!="array" or length==0 or length>1024 or (all(.[]; type=="array" and length==2 and (.[0]|port) and (.[1]|port) and .[0]<=.[1])|not) then error("invalid intervals") else
    sort_by(.[0],.[1]) | reduce .[] as $x ([]; if length>0 and $x[0]<=.[-1][1]+1 then .[-1][1]=([.[-1][1],$x[1]]|max) else .+[$x] end) |
    if length>64 then error("more than 64 disjoint HY2 intervals") else . end end'
}
hop_load() {
  HOP=$(jq -c '.hop // {mode:"external",ports:[],iface:""}' <<< "$OLD")
  jq -e '.mode=="external" or .mode=="local"' <<< "$HOP" >/dev/null || return 1
  if [[ $(jq -r .mode <<< "$HOP") == local ]]; then
    iface_valid "$(jq -r .iface <<< "$HOP")" || return 1
    [[ $(jq -c .ports <<< "$HOP" | intervals) == "$(jq -c .ports <<< "$HOP")" ]] || return 1
  else jq -e '.mode=="external" and (.ports|type=="array" and length==0) and ((.iface // "")=="")' <<< "$HOP" >/dev/null || { err 'Invalid external hopping state'; return 1; }; fi
}

# Normalize only a redundant UDP equality when the SAME rule already
# contains a UDP destination-port match. All other objects remain significant.
nat_canonical() {
  jq -Sc '
    map(if has("rule") then
      .rule.expr |= (
        if any(.[]; .match.left.payload.protocol?=="udp" and .match.left.payload.field?=="dport") then
          map(select(. != {match:{op:"==",left:{meta:{key:"l4proto"}},right:"udp"}}))
        else . end)
    else . end)'
}
nat_expected() {
  jq -Scn --arg t "$TABLE" --argjson hop "$HOP" --argjson p "$PORT" '
    if $hop.mode!="local" then [] else
    [{table:{family:"inet",name:$t,comment:"hy2-hop v2 owned"}},
     {chain:{family:"inet",table:$t,name:"prerouting",type:"nat",hook:"prerouting",prio:-100,policy:"accept",comment:"hy2-hop v2 owned"}}] +
    [$hop.ports[] | {rule:{family:"inet",table:$t,chain:"prerouting",comment:"hy2-hop v2 owned",expr:[
      {match:{op:"==",left:{meta:{key:"iifname"}},right:$hop.iface}},
      {match:{op:"==",left:{fib:{result:"type",flags:["daddr"]}},right:"local"}},
      {match:{op:"==",left:{meta:{key:"l4proto"}},right:"udp"}},
      {match:{op:"==",left:{payload:{protocol:"udp",field:"dport"}},right:(if .[0]==.[1] then .[0] else {range:.} end)}},
      {redirect:{port:$p}}]}}] end' | nat_canonical
}
nat_snapshot() {
  local rules
  rules=$(nft -j list ruleset) || { err 'Cannot inspect nftables/CAP_NET_ADMIN'; return 1; }
  jq -Sce --arg t "$TABLE" '[.nftables[] | select(to_entries|any(.[]; .value.family=="inet" and (.value.table==$t or (.key=="table" and .value.name==$t)))) | walk(if type=="object" then del(.handle,.index) else . end)]' <<< "$rules" | nat_canonical
}
nat_owned() {
  local actual
  actual=$(nat_snapshot) || return 1
  if [[ -e "$NAT_STATE" || -L "$NAT_STATE" ]]; then
    secure "$NAT_STATE" 600 || return 1
    [[ "$actual" == '[]' || "$actual" == "${NAT_MEMORY:-}" || "$actual" == "$(nat_canonical < "$NAT_STATE")" ]] || { err 'Unknown/modified HY2 nft table: refusing replacement'; return 1; }
    # A missing table may be a reboot; a nonempty table needs the complete saved fingerprint.
  else [[ "$actual" == '[]' ]] || { err 'Foreign same-name nft table; no ownership fingerprint'; return 1; }; fi
}
nat_apply() {
  local actual expected batch
  nat_owned || return 1
  actual=$(nat_snapshot) || return 1
  expected=$(nat_expected) || return 1
  if [[ "$actual" == "$expected" ]]; then
    # A failed atomic apply may leave old rules with the intended new fingerprint file.
    if [[ -e "$NAT_STATE" || "$expected" != '[]' ]]; then put "$NAT_STATE" "$expected" || return 1; fi
    return 0
  fi
  if [[ "$expected" != '[]' ]]; then no_local_nat || return 1; fi
  batch=$(jq -cn --arg t "$TABLE" --argjson a "$actual" --argjson e "$expected" '
    {nftables:((if $a|length>0 then [{delete:{table:{family:"inet",name:$t}}}] else [] end) + ($e|map({add:.})))}') || return 1
  # Check-only and apply are both permission/capability gates; inet NAT needs Linux >=5.2.
  nft -c -j -f /dev/stdin <<< "$batch" || { err 'Local inet redirect unavailable: need nftables, Linux >=5.2 and CAP_NET_ADMIN; no kernel upgrade attempted'; return 1; }
  # Persist INTENDED content first: never claim an arbitrary post-apply snapshot.
  NAT_MEMORY=$actual
  put "$NAT_STATE" "$expected" || return 1
  nft -j -f /dev/stdin <<< "$batch" || return 1
  [[ $(nat_snapshot) == "$expected" ]] || { err 'nft post-apply fingerprint mismatch'; return 1; }
  NAT_MEMORY=$expected
}

choose_iface() {
  local routes names
  if [[ -n "$1" ]]; then IFACE=$1
  else
    routes=$(ip -j -4 route show table all default) || return 1
    names=$(ip -j -6 route show table all default) || return 1
    names=$(jq -rn --argjson a "$routes" --argjson b "$names" '[$a[],$b[]] | if any(.[]; has("nexthops") or (.type // "unicast")!="unicast") then error("multipath/unsupported default route") else map(.dev // error("default route without dev")) | unique | .[] end') || return 1
    [[ -n "$names" && "$names" != *$'\n'* ]] || { err 'Ambiguous/missing default interface; set HY2_HOPPING_INTERFACE explicitly'; return 1; }
    IFACE=$names
    if [[ ${PUBLIC_IFACE_ONLY:-0} == 1 ]]; then
    local addresses
    addresses=$(ip -j address show dev "$IFACE") || return 1
    jq -e 'any(.[].addr_info[]?; .scope=="global" and ((.family=="inet6" and (.local|test("^[23]"))) or (.family=="inet" and (.local|test("^(10\\.|127\\.|169\\.254\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.)")|not))))' <<< "$addresses" >/dev/null || { err 'Automatic interface is private/unclear; explicitly set HY2_HOPPING_INTERFACE or HY2_HOPPING_INTERFACE'; return 1; }
    fi
  fi
  iface_valid "$IFACE" || { err 'Invalid interface'; return 1; }
  ip -j link show dev "$IFACE" | jq -e 'length==1 and (.[0].flags|index("UP"))!=null' >/dev/null || { err 'Interface missing/down'; return 1; }
}

no_local_nat() {
  local rules
  rules=$(nft -j list ruleset) || return 1
  nat_owned || return 1
  jq -e --arg t "$TABLE" '[.nftables[] | .chain? | select(.type=="nat" and (.family!="inet" or .table!=$t))] | length==0' <<< "$rules" >/dev/null || { err 'Third-party NAT rules present; refusing local forwarding'; return 1; }
}
main() {
  [[ $(id -u) == 0 ]] || return 1
  if [[ ${1:-} == probe-interface ]]; then PUBLIC_IFACE_ONLY=1; choose_iface "${2:-}"; printf '%s\n' "$IFACE"; return; fi
  [[ ! -L "$D" ]] || return 1
  mkdir -p "$D"; chmod 700 "$D"
  secure "$D" 700 || return 1
  [[ ! -L "$D/lock" ]] || return 1
  exec 9>"$D/lock"; flock -x 9
  if [[ ${1:-} == configure ]]; then
    [[ $# == 4 ]] || return 1
    PORT=$2; HOP=$3; CONFIG=$4
    [[ "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] && (( PORT<=65535 )) || return 1
    OLD=$(jq -cn --argjson hop "$HOP" '{hop:$hop}')
    hop_load || return 1
    local prior='null' previous_port=$PORT previous_hop=$HOP
    if [[ -e "$STATE" ]]; then secure "$STATE" 600 || return 1; prior=$(jq -ce . "$STATE") || return 1; fi
    if ! nat_apply; then
      HOP=$(jq -c '.hop // {mode:"external",ports:[],iface:""}' <<< "$prior")
      PORT=$(jq -r '.port // 1' <<< "$prior")
      nat_apply || err 'Forwarding recovery failed; inspect the owned nft table before retrying'
      return 1
    fi
    if ! put "$STATE" "$(jq -cn --argjson port "$PORT" --argjson hop "$HOP" --arg config "$CONFIG" '{port:$port,hop:$hop,config:$config}')"; then
      HOP=$(jq -c '.hop // {mode:"external",ports:[],iface:""}' <<< "$prior")
      PORT=$(jq -r '.port // 1' <<< "$prior")
      nat_apply || err 'Forwarding recovery failed; inspect the owned nft table before retrying'
      return 1
    fi
  elif [[ ${1:-} == restore ]]; then
    [[ -e "$STATE" ]] || return 0
    secure "$STATE" 600 || return 1
    OLD=$(jq -ce . "$STATE"); hop_load || return 1
    PORT=$(jq -er .port <<< "$OLD"); CONFIG=$(jq -er .config <<< "$OLD")
    jq -e --argjson p "$PORT" 'any(.inbounds[]?; .type=="hysteria2" and .listen_port==$p)' "$CONFIG" >/dev/null || return 1
    choose_iface "$(jq -r .iface <<< "$HOP")" || return 1
    nat_apply
  else err 'Usage: hy2-hop restore'; fi
}
main "$@"
HY2_HOP_HELPER
  local iface
  iface=$(bash "$WORK_DIR/hy2-hop" probe-interface "${HY2_HOPPING_INTERFACE:-}") || return 1
  HY2_HOP_JSON=$(jq -cn --arg i "$iface" --argjson p "$HY2_INTERVALS_JSON" '{mode:"local",ports:$p,iface:$i}') || return 1
  mkdir -p /usr/local/sbin
  install -m 700 "$WORK_DIR/hy2-hop" /usr/local/sbin/hy2-hop
  if [[ "$HY2_HOP_INIT" == systemd ]]; then
    mkdir -p /etc/systemd/system/sing-box.service.d
    cat > /etc/systemd/system/hy2-hop.service <<'HOP_UNIT'
[Unit]
Description=HY2 local UDP forwarding
After=network-online.target
Wants=network-online.target
Before=sing-box.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hy2-hop restore
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
HOP_UNIT
    cat > /etc/systemd/system/sing-box.service.d/hy2-hop.conf <<'HOP_DROP'
[Unit]
Requires=hy2-hop.service
After=hy2-hop.service
[Service]
ExecStartPre=/usr/local/sbin/hy2-hop restore
HOP_DROP
    systemctl daemon-reload && systemctl enable hy2-hop.service
  else
    cat > /etc/init.d/hy2-hop <<'HOP_RC'
#!/sbin/openrc-run
name="hy2-hop"
depend() { need net; before sing-box; }
start() { /usr/local/sbin/hy2-hop restore; }
stop() { return 0; }
HOP_RC
    chmod 755 /etc/init.d/hy2-hop
    rc-update add hy2-hop default
    HY2_RC_DEP=hy2-hop
  fi
  /usr/local/sbin/hy2-hop configure "$HY2_LISTEN_PORT" "$HY2_HOP_JSON" "$CONFIG_FILE"
}

cleanup_installer() {
  local status=$?
  trap - EXIT
  if [[ "${CONFIG_COMMITTED:-0}" == 1 && "${CONFIG_ACCEPTED:-0}" != 1 ]]; then rollback_config || true; fi
  [[ -z "${WORK_DIR:-}" ]] || rm -rf "$WORK_DIR"
  exit "$status"
}

restart_detached() {
  # Restore any unaccepted config before re-execution rotates node credentials.
  trap '' HUP
  if [[ "${CONFIG_COMMITTED:-0}" == 1 && "${CONFIG_ACCEPTED:-0}" != 1 ]]; then rollback_config || true; fi
  INSTALL_DAEMONIZED=1 nohup bash "${BASH_SOURCE[0]}" </dev/null >> "$INSTALL_LOG" 2>&1 &
  printf '[*] Continuing in background; log: %s\n' "$INSTALL_LOG" >&2 || true
  exit 0
}

main() {
  set -euo pipefail
  umask 077
  [[ "$(id -u)" == 0 ]] || { fail 'Run as root'; return 1; }
  # Original disconnect behavior: rerun detached on HUP. A rerun regenerates
  # node defaults. The daemon writes directly to a private log (no tee pipe).
  INSTALL_LOG="${INSTALL_LOG:-/root/install_reality.log}"
  touch "$INSTALL_LOG"; chmod 600 "$INSTALL_LOG"
  if [[ "${INSTALL_DAEMONIZED:-0}" == 1 ]]; then
    trap '' HUP
    exec >> "$INSTALL_LOG" 2>&1
  else
    trap restart_detached HUP
  fi
  _cmd jq || install_packages jq
  init_settings
  hy2_hop_prepare
  validate_existing_config
  _cmd curl || install_packages curl ca-certificates
  if [[ "$MODE" == hy2 || "$MODE" == both ]]; then _cmd openssl || install_packages openssl; fi
  install_singbox
  mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
  WORK_DIR=$(mktemp -d "$CONFIG_DIR/.installer.XXXXXX")
  CONFIG_COMMITTED=0; CONFIG_ACCEPTED=0
  trap cleanup_installer EXIT
  if [[ "$MODE" == reality || "$MODE" == both ]]; then select_reality_dest; generate_credentials; fi
  if [[ "$MODE" == ss ]]; then generate_ss_credentials; fi
  if [[ "$MODE" == hy2 || "$MODE" == both ]]; then generate_hy2_credentials; fi
  # Avoid unset legacy port in HY2-only self-checks.
  ACTUAL_LISTEN_PORT="${ACTUAL_LISTEN_PORT:-$HY2_LISTEN_PORT}"
  build_nodes
  probe_hy2_support
  merge_candidate "$NEW_INBOUNDS" "$WORK_DIR/config.json"
  prepare_outputs
  check_and_open_firewall
  hy2_hop_install
  commit_candidate "$WORK_DIR/config.json"
  if ! start_service; then fail 'Service start failed; restoring previous configuration'; return 1; fi
  if ! self_check; then fail 'Protocol self-check failed; restoring previous configuration'; return 1; fi
  CONFIG_ACCEPTED=1
  publish_outputs
  setup_logrotate
  if ! _cmd ssh-keygen; then
    if _cmd apk || _cmd zypper || _cmd pacman; then install_packages openssh
    elif _cmd dnf || _cmd yum; then install_packages openssh-clients
    else install_packages openssh-client
    fi
  fi
  setup_ssh_key
  setup_alias
  _ok2 "Installation complete: MODE=$MODE. Read $CONFIG_DIR/node_output.txt or run shownode."
}

if [[ "${INSTALLER_SOURCE_ONLY:-0}" != 1 ]]; then main "$@"; fi
