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
    count=$((count + end - start + 1)); only="$start"
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

install_singbox() {
  if [[ -n "${BIN:-}" ]] && "$BIN" version >/dev/null 2>&1; then
    _ok2 "Keeping installed core: $("$BIN" version | head -n1)"
    return 0
  fi
  local arch version tmp tarball binfile
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;;
    i?86) arch=386 ;; armv7l|armv6l|armhf) arch=armv7 ;;
    riscv64|s390x) arch=$(uname -m) ;; *) fail 'Unsupported architecture'; return 1 ;;
  esac
  version=$(curl -fsSL --connect-timeout 10 -m 20 https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -er '.tag_name | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) | ltrimstr("v")') || return 1
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
  install -m 755 "$binfile" /usr/local/bin/sing-box && cmp -s "$binfile" /usr/local/bin/sing-box || { rm -rf "$tmp"; return 1; }
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

valid_tls_pair() {
  local cert="$1" key="$2"
  [[ -s "$cert" && -s "$key" ]] || return 1
  openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null 2>&1 || return 1
  openssl verify -CAfile "$cert" -verify_hostname "$HY2_SNI" "$cert" >/dev/null 2>&1 || return 1
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
  if [[ "${HY2_RC_DEP:-}" == hy2-limit ]]; then
    # OpenRC dependency is HY2-only; non-HY2 installs retain the original unit.
    local hy2_need='need net hy2-limit;'
    local hy2_pre='start_pre() { /usr/local/sbin/hy2-limit restore; }'
  else local hy2_need='need net;' hy2_pre=''; fi
  if _cmd systemctl && [[ -d /run/systemd/system ]]; then
    mkdir -p /etc/systemd/system || return 1
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
    if [[ "${HY2_LIMIT_RECOVERY_FAILED:-0}" == 1 ]]; then
      _warn2 'Previous config restored but sing-box kept stopped: HY2 protection recovery failed.'
    else restart_service || _warn2 'Previous config restored but service recovery failed; inspect service logs.'; fi
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
    for target in https://www.google.com/generate_204 https://cloudflare.com/cdn-cgi/trace; do
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

# Install only ordinary HY2 user-space tools; never kernel modules/capabilities.
# Keep this outside the embedded helper: standalone commands never install packages.
hy2_limit_dependency_package() {
  local tool=$1 manager=$2
  case "$tool" in
    tc) case "$manager" in apk) printf '%s\n' iproute2-tc ;; dnf|yum) printf '%s\n' iproute-tc ;; *) printf '%s\n' iproute2 ;; esac ;;
    ip) case "$manager" in dnf|yum) printf '%s\n' iproute ;; *) printf '%s\n' iproute2 ;; esac ;;
    flock) case "$manager" in apk) printf '%s\n' flock ;; *) printf '%s\n' util-linux ;; esac ;;
    cmp) printf '%s\n' diffutils ;;
    nft) printf '%s\n' nftables ;;
    sha256sum|stat|mktemp|dirname|id|mkdir|chmod|mv|rm|cp|install|cat) printf '%s\n' coreutils ;;
    *) fail "No safe HY2 dependency package mapping for $tool"; return 1 ;;
  esac
}

hy2_limit_ensure_tools() {
  local tool manager='' package existing seen
  local -a missing=() packages=()
  for tool in "$@"; do _cmd "$tool" || missing+=("$tool"); done
  ((${#missing[@]})) || return 0
  # Same precedence as install_packages; do not guess from /etc/os-release.
  for tool in apk apt-get dnf yum zypper pacman; do
    if _cmd "$tool"; then manager=$tool; break; fi
  done
  [[ -n "$manager" ]] || { fail "HY2 required tools missing: ${missing[*]}; no supported package manager, install manually"; return 1; }
  for tool in "${missing[@]}"; do
    package=$(hy2_limit_dependency_package "$tool" "$manager") || return 1
    seen=0
    for existing in "${packages[@]}"; do [[ "$existing" != "$package" ]] || seen=1; done
    [[ "$seen" == 1 ]] || packages+=("$package")
  done
  _info2 "Installing HY2 user-space dependencies: ${packages[*]}"
  install_packages "${packages[@]}" || { fail "HY2 dependency installation failed: ${packages[*]}"; return 1; }
  hash -r
  for tool in "${missing[@]}"; do
    _cmd "$tool" || { fail "HY2 dependency installation returned success but $tool is still missing (check PATH/packages)"; return 1; }
  done
}

hy2_limit_stat_check() {
  # Test GNU/BusyBox-compatible -c before ANY trusted-state owner/mode reads.
  local owner mode probe=${BASH_SOURCE[0]}
  owner=$(stat -c %u "$probe") && mode=$(stat -c %a "$probe") &&
    [[ "$owner" =~ ^[0-9]+$ && "$mode" =~ ^[0-7]{3,4}$ ]] || {
      fail 'HY2 requires stat -c %u/%a support; install a compatible user-space stat'; return 1;
    }
}

hy2_limit_dependencies() {
  local json probe rc
  hy2_limit_ensure_tools tc ip flock stat mktemp cmp dirname id mkdir chmod mv rm cp install cat || return 1
  # jq is installed by main before init_settings; retain that existing install path.
  _cmd jq && jq -en 'all([1,2][]; type=="number") and (([2,1]|sort)==[1,2])' >/dev/null || {
    fail 'HY2 requires a working jq with JSON/all/sort support'; return 1;
  }
  hy2_limit_stat_check || return 1
  # Accept BusyBox applets when they support the actual options we use.
  probe=$(mktemp "${TMPDIR:-/tmp}/hy2-deps.XXXXXX") || { fail 'HY2 mktemp failed; check tool support and temporary-directory permissions'; return 1; }
  cmp -s "$probe" /dev/null || { rm -f "$probe"; fail 'HY2 requires working cmp -s'; return 1; }
  printf x > "$probe" || { rm -f "$probe"; fail 'HY2 temporary-file write failed; check permissions'; return 1; }
  if cmp -s "$probe" /dev/null; then rc=0; else rc=$?; fi
  [[ "$rc" == 1 ]] || { rm -f "$probe"; fail 'HY2 cmp -s must distinguish different files (exit 1)'; return 1; }
  if ! (flock -x 9) 9>"$probe"; then
    rm -f "$probe"
    fail 'HY2 flock -x failed; check util-linux/flock support and filesystem permissions'; return 1
  fi
  rm -f "$probe" || return 1
  # Read-only capability probes. Failure is NOT permission to change networking,
  # install Linux kernels, modprobe, grant capabilities, or replace existing tools.
  json=$(tc -j qdisc show) && jq -e 'type=="array" and all(.[];type=="object")' <<< "$json" >/dev/null || {
    fail 'HY2 tc JSON query failed: need iproute2 tc with -j support and network inspection permission; inspect diagnostics'; return 1;
  }
  for probe in -4 -6; do
    json=$(ip -j "$probe" route show table all default) && jq -e 'type=="array" and all(.[];type=="object")' <<< "$json" >/dev/null || {
      fail "HY2 ip $probe JSON route query failed: need iproute2 -j support and network inspection permission; inspect diagnostics"; return 1;
    }
  done
  # Disabling needs tc ownership reads but must not acquire a new NAT dependency.
  [[ "${1:-true}" == true ]] || return 0
  # Only supplement a missing inspection backend. Existing partial legacy tools
  # still face the helper's unchanged strict dual-stack NAT check.
  if ! _cmd nft && ! { _cmd iptables-save && _cmd ip6tables-save; }; then
    hy2_limit_ensure_tools nft || return 1
  fi
  if _cmd nft; then
    json=$(nft -j list ruleset) && jq -e 'type=="object" and (.nftables|type=="array")' <<< "$json" >/dev/null || {
      fail 'HY2 nft JSON ruleset read failed: check nftables JSON support and CAP_NET_ADMIN/root permissions; no privileges or rules changed'; return 1;
    }
  fi
}

# HY2-only egress shaping integration. No files/tc calls on the first opt-out run.
hy2_limit_prepare() {
  HY2_LIMIT_ACTIVE=0; HY2_LIMIT_CHANGED=0; HY2_LIMIT_OLD='null'
  local state=/etc/hy2-limit/state.json enabled=0 requested=${ENABLE_VPS_SHAPING-}
  if [[ -e /etc/hy2-limit || -L /etc/hy2-limit ]]; then
    hy2_limit_ensure_tools stat || return 1
    hy2_limit_stat_check || return 1
    [[ ! -L /etc/hy2-limit && $(stat -c %u /etc/hy2-limit) == 0 && $(stat -c %a /etc/hy2-limit) == 700 ]] || { fail 'Unsafe /etc/hy2-limit'; return 1; }
    if [[ -e "$state" || -L "$state" ]]; then
      [[ ! -L "$state" && $(stat -c %u "$state") == 0 && $(stat -c %a "$state") == 600 ]] || { fail 'Unsafe HY2 limiter state'; return 1; }
      HY2_LIMIT_OLD=$(jq -cse 'select(length==1) | .[0] | select((.version==1 or .version==2) and (.enabled|type=="boolean") and (.iface|type=="string" and test("^[a-zA-Z0-9_.:-]{1,15}$")) and (.port|type=="number" and floor==. and .>=1 and .<=65535) and (.mbps|type=="number" and floor==. and .>=1 and .<=10000))' "$state") || return 1
      [[ $(jq -r .enabled <<< "$HY2_LIMIT_OLD") != true ]] || enabled=1
    fi
  fi
  [[ -z "$requested" || "$requested" == 0 || "$requested" == 1 ]] || { fail 'ENABLE_VPS_SHAPING must be 0 or 1'; return 1; }
  if [[ "$MODE" != hy2 && "$MODE" != both ]]; then
    if [[ "$enabled" == 1 || "$requested" == 1 || $(jq -r '.hop.mode // "external"' <<< "$HY2_LIMIT_OLD") == local ]]; then fail 'HY2 protection enabled: run hy2-limit disable-all BEFORE switching to reality/ss'; return 1; fi
    HY2_LIMIT_DETACH=1
    return 0
  fi
  if [[ -z "$requested" ]]; then requested=$enabled; fi
  [[ "$requested" == 1 || "$HY2_LIMIT_OLD" != null || ${HY2_PORT_HOPPING_MODE:-external} == local ]] || return 0
  HY2_LIMIT_ENABLED=$([[ "$requested" == 1 ]] && printf true || printf false)
  HY2_LIMIT_MBPS=${VPS_UPLOAD_MBIT:-}
  HY2_LIMIT_IFACE=${VPS_SHAPING_INTERFACE:-}
  if [[ "$HY2_LIMIT_OLD" != null ]]; then
    HY2_LIMIT_MBPS=${HY2_LIMIT_MBPS:-$(jq -r .mbps <<< "$HY2_LIMIT_OLD")}
    HY2_LIMIT_IFACE=${HY2_LIMIT_IFACE:-$(jq -r .iface <<< "$HY2_LIMIT_OLD")}
  fi
  HY2_LIMIT_MBPS=${HY2_LIMIT_MBPS:-100}
  [[ "$HY2_LIMIT_MBPS" =~ ^[1-9][0-9]{0,4}$ ]] && (( HY2_LIMIT_MBPS<=10000 )) || { fail 'VPS_UPLOAD_MBIT must be integer 1..10000 Mbps'; return 1; }
  if [[ ${HY2_PORT_HOPPING_MODE:-external} == local ]]; then
    hy2_limit_ensure_tools nft || return 1
  fi
  hy2_limit_dependencies "$HY2_LIMIT_ENABLED" || return 1
  if _cmd systemctl && [[ -d /run/systemd/system ]]; then HY2_LIMIT_INIT=systemd
  elif _cmd rc-service && _cmd rc-update; then HY2_LIMIT_INIT=openrc
  else fail 'HY2 limiter requires systemd or OpenRC'; return 1; fi
  HY2_LIMIT_ACTIVE=1
}

hy2_limit_install() {
  if [[ "${HY2_LIMIT_DETACH:-0}" == 1 && -e /etc/systemd/system/sing-box.service.d/hy2-limit.conf ]]; then
    local drop=/etc/systemd/system/sing-box.service.d/hy2-limit.conf
    cat > "$WORK_DIR/dropin.expected" <<'HY2_DETACH_EXPECTED'
# hy2-limit v1 -- installer-owned
[Unit]
Requires=hy2-limit.service
After=hy2-limit.service
[Service]
ExecStartPre=/usr/local/sbin/hy2-limit restore
HY2_DETACH_EXPECTED
    [[ ! -L "$drop" && $(stat -c %u "$drop") == 0 ]] && cmp -s "$WORK_DIR/dropin.expected" "$drop" || { fail 'Unknown HY2 drop-in; refusing removal'; return 1; }
    cp -p "$drop" "$WORK_DIR/dropin.previous" && rm -f "$drop" || return 1
    HY2_LIMIT_DETACHED=1
    systemctl daemon-reload || return 1
  fi
  [[ "${HY2_LIMIT_ACTIVE:-0}" == 1 ]] || return 0
  local p
  # Refuse collisions, even with files bearing a similar name. Exact content is
  # compared before reusing an existing helper/service; no unknown files replaced.
  mkdir -p /usr/local/sbin /usr/local/bin
  mkdir -p /etc/hy2-limit; chmod 700 /etc/hy2-limit
  cat > "$WORK_DIR/hy2-limit" <<'HY2_LIMIT_HELPER'
#!/bin/bash
# hy2-limit v2 -- installer-owned HY2 egress and local hopping module
set -euo pipefail
umask 077
D=/etc/hy2-limit
STATE=$D/state.json
LIVE=/run/hy2-limit-live.json
NAT_STATE=$D/nat.json
TABLE=hy2_hopping
# At most 64 merged intervals => 128 software flower filters, never per-port expansion.
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
  else [[ "$HOP" == '{"mode":"external","ports":[],"iface":""}' ]] || { err 'Invalid external hopping state'; return 1; }; fi
}
source_ranges() {
  if [[ $(jq -r .mode <<< "$HOP") == local ]]; then
    jq -c --argjson p "$PORT" '.ports+[[$p,$p]]' <<< "$HOP" | intervals
  else printf '[[%s,%s]]\n' "$PORT" "$PORT"; fi
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
      {redirect:{port:$p}}]}}] end'
}
nat_snapshot() {
  local rules
  rules=$(nft -j list ruleset) || { err 'Cannot inspect nftables/CAP_NET_ADMIN'; return 1; }
  jq -Sce --arg t "$TABLE" '[.nftables[] | select(to_entries|any(.[]; .value.family=="inet" and (.value.table==$t or (.key=="table" and .value.name==$t)))) | walk(if type=="object" then del(.handle,.index) else . end)]' <<< "$rules"
}
nat_owned() {
  local actual
  actual=$(nat_snapshot) || return 1
  if [[ -e "$NAT_STATE" || -L "$NAT_STATE" ]]; then
    secure "$NAT_STATE" 600 || return 1
    [[ "$actual" == '[]' || "$actual" == "${NAT_MEMORY:-}" || "$actual" == "$(jq -Sc . "$NAT_STATE")" ]] || { err 'Unknown/modified HY2 nft table: refusing replacement'; return 1; }
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
err() { printf '[hy2-limit] %s\n' "$*" >&2; return 1; }
rate() {
  [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 10000 )) || { err 'Mbps must be an integer in 1..10000 (not MB/s)'; return 1; }
}
iface_valid() { [[ "$1" =~ ^[a-zA-Z0-9_.:-]{1,15}$ && "$1" != lo && "$1" != -* ]]; }
secure() {
  [[ ! -L "$1" && $(stat -c %u "$1") == 0 && $(stat -c %a "$1") == "$2" ]] || { err "Unsafe owner/mode/symlink: $1"; return 1; }
}
load() {
  OLD='null'
  if [[ -e "$STATE" || -L "$STATE" ]]; then
    secure "$STATE" 600 || return 1
    OLD=$(jq -cse 'select(length==1) | .[0] | select(type=="object" and (.version==1 or .version==2) and (.enabled|type=="boolean") and (.iface|type=="string") and (.port|type=="number" and floor==. and .>=1 and .<=65535) and (.mbps|type=="number" and floor==. and .>=1 and .<=10000))' "$STATE") || { err 'Invalid state JSON'; return 1; }
    iface_valid "$(jq -r .iface <<< "$OLD")" || return 1
    hop_load || return 1
  fi
}
put() { local tmp; tmp=$(mktemp "$(dirname "$1")/.hy2-write.XXXXXX") || return 1; printf '%s\n' "$2" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$1"; }
snapshot() {
  local q f r c parent extra='[]'
  q=$(tc -j qdisc show dev "$IFACE") || return 1
  f=$(tc -j filter show dev "$IFACE" parent 1e70:) || return 1
  r=$(tc -j filter show dev "$IFACE" root) || return 1
  c=$(tc -j class show dev "$IFACE") || return 1
  for parent in 1e70:1 1e70:2 1e70:3 1e73:; do
    extra=$(jq -cn --argjson a "$extra" --argjson b "$(tc -j filter show dev "$IFACE" parent "$parent")" '$a+[$b]') || return 1
  done
  jq -Scn --argjson q "$q" --argjson f "$f" --argjson r "$r" --argjson c "$c" --argjson e "$extra" '{q:($q|map(del(.refcnt))),f:$f,r:$r,c:$c,e:$e}'
}
owned() {
  if [[ -n ${MEMORY_LIVE:-} ]]; then
    [[ $(snapshot) == "$MEMORY_LIVE" ]] || { err 'tc rules differ from in-process transaction snapshot'; return 1; }
    return 0
  fi
  [[ -f "$LIVE" ]] && secure "$LIVE" 600 || { err 'No trusted live-rule ownership record'; return 1; }
  [[ $(snapshot) == "$(< "$LIVE")" ]] || { err 'tc rules changed outside hy2-limit; refusing to delete/replace them'; return 1; }
}
default_queue() {
  local q filters handle
  q=$(tc -j qdisc show dev "$IFACE") || return 1
  # Only unconfigured kernel defaults, handle 0:, with no children/ingress/clsact.
  jq -e 'length==1 and .[0].root==true and .[0].handle=="0:" and (.[0].kind=="fq_codel" or .[0].kind=="pfifo_fast" or .[0].kind=="fq")' <<< "$q" >/dev/null || { err 'Custom/multiqueue/noqueue/ingress/clsact qdisc is unsupported; existing queues preserved'; return 1; }
  for handle in root 0:; do
    if [[ "$handle" == root ]]; then filters=$(tc -j filter show dev "$IFACE" root) || return 1
    else filters=$(tc -j filter show dev "$IFACE" parent "$handle") || return 1; fi
    [[ $(jq 'length' <<< "$filters") == 0 ]] || { err 'Existing root filters; refusing takeover'; return 1; }
  done
}
no_local_nat() {
  local rules tool checked=0 legacy=0
  # Conservative compatibility restriction, not an assertion that Docker NAT is unsafe.
  if command -v nft >/dev/null; then
    rules=$(nft -j list ruleset) || { err 'Cannot inspect nftables'; return 1; }
    nat_owned || return 1
    jq -e --arg t "$TABLE" '[.nftables[] | .chain? | select(.type=="nat" and (.family!="inet" or .table!=$t))] | length==0' <<< "$rules" >/dev/null || { err 'Third-party local NAT is not supported; only the complete owned HY2 inet table is allowed'; return 1; }
    checked=1
  fi
  for tool in iptables-save ip6tables-save; do
    if command -v "$tool" >/dev/null; then
      rules=$("$tool" -t nat) || { err "Cannot inspect $tool NAT table"; return 1; }
      [[ "$rules" != *'-A '* ]] || { err 'This version does not support local NAT-rule environments'; return 1; }
      checked=1; legacy=$((legacy+1))
    fi
  done
  [[ "$checked" == 1 && ( "$legacy" == 0 || "$legacy" == 2 ) ]] || { err 'Install nft or BOTH iptables-save and ip6tables-save for dual-stack NAT inspection'; return 1; }
}
choose_iface() {
  local routes names
  if [[ -n "$1" ]]; then IFACE=$1
  else
    routes=$(ip -j -4 route show table all default) || return 1
    names=$(ip -j -6 route show table all default) || return 1
    names=$(jq -rn --argjson a "$routes" --argjson b "$names" '[$a[],$b[]] | if any(.[]; has("nexthops") or (.type // "unicast")!="unicast") then error("multipath/unsupported default route") else map(.dev // error("default route without dev")) | unique | .[] end') || return 1
    [[ -n "$names" && "$names" != *$'\n'* ]] || { err 'Ambiguous/missing default interface; set VPS_SHAPING_INTERFACE explicitly'; return 1; }
    IFACE=$names
    if [[ ${PUBLIC_IFACE_ONLY:-0} == 1 ]]; then
    local addresses
    addresses=$(ip -j address show dev "$IFACE") || return 1
    jq -e 'any(.[].addr_info[]?; .scope=="global" and ((.family=="inet6" and (.local|test("^[23]"))) or (.family=="inet" and (.local|test("^(10\\.|127\\.|169\\.254\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.)")|not))))' <<< "$addresses" >/dev/null || { err 'Automatic interface is private/unclear; explicitly set HY2_HOPPING_INTERFACE or VPS_SHAPING_INTERFACE'; return 1; }
    fi
  fi
  iface_valid "$IFACE" || { err 'Invalid interface'; return 1; }
  ip -j link show dev "$IFACE" | jq -e 'length==1 and (.[0].flags|index("UP"))!=null' >/dev/null || { err 'Interface missing/down'; return 1; }
}
remove_owned() { owned && tc qdisc del dev "$IFACE" root && rm -f "$LIVE" && MEMORY_LIVE=''; }
record() {
  MEMORY_LIVE=$(snapshot) || { MEMORY_LIVE=''; err 'Cannot inspect newly created rules: automatic compensation cannot safely identify them'; return 1; }
  # Do not absorb objects added by another tc manager into our ownership record.
  jq -e --argjson ranges "$RANGES" --argjson n "${FILTER_COUNT:-0}" '
    (.q | all(.[];
      (.kind=="prio" and .handle=="1e70:" and .root==true) or
      (.kind=="tbf" and .handle=="1e73:" and .parent=="1e70:3") or
      (.kind=="pfifo" and .handle=="0:" and (.parent=="1e70:1" or .parent=="1e70:2" or .parent=="1e70:3")))) and
    ([.q[]|select(.root==true)]|length==1) and
    (.f | all(.[]; .kind=="flower" and (.pref>=170 and .pref<298 and ((.pref%2==0 and .protocol=="ip") or (.pref%2==1 and .protocol=="ipv6"))) and ((has("options")|not) or .options.handle==1))) and
    ([.f[]|select(has("options"))]|length<=128) and
    (.f | group_by([.pref,.protocol]) | all(.[];
      ([.[]|select(has("options"))]|length==1) and
      ([.[]|select(has("options")|not)]|length<=1))) and
    ([.f[]|select(has("options"))]|length==$n) and
    (.f | all(.[]|select(has("options"));
      . as $f | $ranges[((.pref-170)/2|floor)] as $p |
      .options.classid=="1e70:3" and .options.keys.ip_proto=="udp" and
      (if $p[0]==$p[1] then .options.keys.src_port==$p[0]
       else .options.keys.src_port_min==$p[0] and .options.keys.src_port_max==$p[1] end))) and
    (.r|length==0) and (.e|all(.[];length==0)) and
    (.c|all(.[]; (.kind=="prio" and (.handle=="1e70:1" or .handle=="1e70:2" or .handle=="1e70:3")) or (.kind=="tbf" and .handle=="1e73:1")))
  ' <<< "$MEMORY_LIVE" >/dev/null || { MEMORY_LIVE=''; err 'Unexpected object during tc transaction; refusing to claim ownership'; return 1; }
  put "$LIVE" "$MEMORY_LIVE"
}
current_hy2() {
  [[ "$OLD" != null ]] || return 1
  local config
  config=$(jq -r '.config // "/etc/sing-box/config.json"' <<< "$OLD")
  [[ "$config" == /* && "$config" != *$'\n'* && ! -L "$config" && -f "$config" && $(stat -c %u "$config") == 0 ]] || { err 'Cannot trust current sing-box config'; return 1; }
  [[ $(stat -c %a "$config") == 600 ]] || { err 'Expected private root config mode 600'; return 1; }
  jq -e --argjson port "$(jq -r .port <<< "$OLD")" 'any(.inbounds[]?; .type=="hysteria2" and .tag=="hy2-in" and .listen_port==$port)' "$config" >/dev/null || { err 'Saved port is not an active managed HY2 inbound; refusing historical-port shaping'; return 1; }
}
stop_hy2() {
  printf '%s\n' '[hy2-limit] CRITICAL: stopping sing-box because protection cannot be safely restored.' >&2 || true
  if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then systemctl stop sing-box || true
  elif command -v rc-service >/dev/null; then rc-service sing-box stop || true; fi
}
create_rules() {
  local burst=$(( MBPS * 1250 ))
  (( burst >= 16384 )) || burst=16384
  (( burst <= 12500000 )) || burst=12500000
  # 10ms of bytes at rate (>=rate/HZ for HZ>=100), bounded 16KiB..12.5MB.
  tc qdisc add dev "$IFACE" root handle 1e70: prio bands 3 priomap 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 || return 1
  CREATED=1; FILTER_COUNT=0
  record || return 1
  tc qdisc add dev "$IFACE" parent 1e70:3 handle 1e73: tbf rate "${MBPS}mbit" burst "$burst" latency 100ms || return 1
  record || return 1
  local interval first last match pref=170 proto
  while IFS= read -r interval; do
    first=$(jq -r '.[0]' <<< "$interval"); last=$(jq -r '.[1]' <<< "$interval")
    match=$first; [[ "$first" == "$last" ]] || match="$first-$last"
    for proto in ip ipv6; do
      tc filter add dev "$IFACE" parent 1e70: protocol "$proto" pref "$pref" handle 1 flower skip_hw ip_proto udp src_port "$match" classid 1e70:3 || {
        err 'HY2 flower UDP source/range classifier unsupported; refusing incomplete limit'; return 1;
      }
      FILTER_COUNT=$((FILTER_COUNT+1))
      record || return 1
      pref=$((pref+1))
    done
  done < <(printf '%s\n' "$RANGES" | jq -c '.[]')
}
recover() {
  local rc=$? saved_iface="${IFACE:-}"
  trap - EXIT HUP INT TERM
  if [[ ${TX:-0} == 1 ]]; then
    printf '%s\n' '[hy2-limit] Operation failed; attempting rule/state rollback.' >&2
    if [[ ${CREATED:-0} == 1 ]]; then
      if ! remove_owned; then
        printf '%s\n' '[hy2-limit] CRITICAL: partial rules could not be safely removed; inspect tc and live.json.' >&2
        stop_hy2
        exit 1
      fi
    fi
    if [[ "$OLD" != null && $(jq -r .enabled <<< "$OLD") == true && ${REMOVED:-0} == 1 ]]; then
      IFACE=$(jq -r .iface <<< "$OLD"); PORT=$(jq -r .port <<< "$OLD"); MBPS=$(jq -r .mbps <<< "$OLD")
      HOP=$(jq -c '.hop // {mode:"external",ports:[],iface:""}' <<< "$OLD")
      RANGES=$(source_ranges) || { stop_hy2; exit 1; }
      CREATED=0
      if default_queue && create_rules; then printf '%s\n' '[hy2-limit] Previous enabled rules restored.' >&2
      else printf '%s\n' '[hy2-limit] CRITICAL: previous protection could NOT be restored; stop HY2 and inspect tc.' >&2; stop_hy2; fi
    fi
    if [[ ${NAT_TX:-0} == 1 ]]; then
      HOP=$(jq -c '.hop // {mode:"external",ports:[],iface:""}' <<< "$OLD")
      PORT=$(jq -r '.port // 1' <<< "$OLD")
      if ! nat_apply; then err 'CRITICAL: NAT rollback failed' || true; stop_hy2; fi
      if [[ ${OLD_NAT:-null} == null && $(nat_snapshot) == '[]' ]]; then rm -f "$NAT_STATE"; fi
    fi
    if [[ "$OLD" == null ]]; then rm -f "$STATE"; else put "$STATE" "$OLD" || true; fi
  fi
  exit "$rc"
}
change() {
  local enabled=$1 new=$2 newiface=$3 newport=$4 oldiface='' live_old=''
  [[ "$newport" =~ ^[1-9][0-9]{0,4}$ ]] && (( newport<=65535 )) || { err 'Invalid local UDP port'; return 1; }
  rate "$new" || return 1
  HOP=${NEW_HOP:-$(jq -c '.hop // {mode:"external",ports:[],iface:""}' <<< "$OLD")}
  PORT=$newport; RANGES=$(source_ranges) || return 1
  if [[ $(jq -r .mode <<< "$HOP") == local ]]; then
    local saved=$HOP; choose_iface "$(jq -r .iface <<< "$HOP")" || return 1; HOP=$saved
  fi
  if [[ $(jq -r .mode <<< "$HOP") == local || -e "$NAT_STATE" ]]; then nat_owned || return 1; fi
  if [[ "$OLD" != null ]]; then oldiface=$(jq -r .iface <<< "$OLD"); fi
  if [[ "$OLD" != null && $(jq -r .enabled <<< "$OLD") == true ]]; then
    IFACE=$oldiface
    if [[ -e "$LIVE" ]]; then owned || return 1
    else default_queue || return 1; fi
  elif [[ -e "$LIVE" ]]; then err 'Unexpected ownership record; manual inspection required'; return 1; fi
  if [[ "$enabled" == true ]]; then
    choose_iface "$newiface" || return 1
    no_local_nat || return 1
    if [[ "$IFACE" != "$oldiface" || ! -e "$LIVE" ]]; then default_queue || return 1; fi
  else IFACE=${newiface:-$oldiface}; iface_valid "$IFACE" || { err 'Invalid interface in disabled state'; return 1; }; fi
  TARGET=$IFACE
  OLD_NAT=null; [[ ! -e "$NAT_STATE" ]] || OLD_NAT=$(cat "$NAT_STATE")
  TX=1; CREATED=0; REMOVED=0
  trap recover EXIT
  trap 'exit 1' HUP INT TERM
  if [[ -e "$LIVE" ]]; then IFACE=$oldiface; remove_owned || return 1; REMOVED=1; fi
  # Old enabled state without live record denotes reboot/default queues.
  if [[ "$OLD" != null && $(jq -r .enabled <<< "$OLD") == true ]]; then REMOVED=1; fi
  IFACE=$TARGET; MBPS=$new; PORT=$newport
  if [[ "$enabled" == true ]]; then create_rules || return 1; fi
  if [[ $(jq -r .mode <<< "$HOP") == local || -e "$NAT_STATE" ]]; then NAT_TX=1; nat_apply || return 1; fi
  local next
  CONFIG_PATH=${CONFIG_PATH:-$(jq -r '.config // "/etc/sing-box/config.json"' <<< "$OLD")}
  next=$(jq -cn --arg config "$CONFIG_PATH" --argjson enabled "$enabled" --arg iface "$IFACE" --argjson port "$PORT" --argjson mbps "$MBPS" --argjson hop "$HOP" '{version:2,hop:$hop,enabled:$enabled,iface:$iface,port:$port,mbps:$mbps,config:$config}') || return 1
  put "$STATE" "$next" || return 1
  TX=0; trap - EXIT HUP INT TERM
  printf '[hy2-limit] enabled=%s interface=%s UDP source=%s aggregate=%s Mbps\n' "$enabled" "$IFACE" "$PORT" "$MBPS" || true
}
main() {
  if [[ ${1:-} == probe-interface && $# == 2 ]]; then PUBLIC_IFACE_ONLY=1; choose_iface "$2" || return 1; printf '%s\n' "$IFACE"; return 0; fi
  [[ $(id -u) == 0 ]] || { err 'Run as root'; return 1; }
  local cmd=${1:-status} p m i
  for p in jq flock stat; do command -v "$p" >/dev/null || { err "Required command missing: $p"; return 1; }; done
  if [[ ! -e "$D" && ! -L "$D" ]]; then mkdir -m 700 "$D"; fi
  secure "$D" 700 || return 1
  [[ ! -L "$D/lock" ]] || return 1
  exec 9>"$D/lock"; flock -x 9
  load || return 1
  HOP=$(jq -c '.hop // {mode:"external",ports:[],iface:""}' <<< "$OLD")
  if [[ "$cmd" == restore && ( "$OLD" == null || ( $(jq -r .enabled <<< "$OLD") == false && $(jq -r .mode <<< "$HOP") == external ) ) ]]; then return 0; fi
  for p in tc ip; do command -v "$p" >/dev/null || { err "Required command missing: $p"; return 1; }; done
  case "$cmd" in
    status)
      if [[ "$OLD" == null ]]; then printf '%s\n' 'HY2 limiter not configured'; return 0; fi
      printf '%s\n' "$OLD" | jq .
      if [[ $(jq -r .mode <<< "$HOP") == local ]]; then PORT=$(jq -r .port <<< "$OLD"); [[ $(nat_snapshot) == "$(nat_expected)" ]] && nat_owned || return 1; fi
      if [[ $(jq -r .enabled <<< "$OLD") == true ]]; then
        IFACE=$(jq -r .iface <<< "$OLD"); owned || return 1
        tc -s qdisc show dev "$IFACE"; tc -s filter show dev "$IFACE" parent 1e70:
      fi ;;
    set)
      [[ $# == 2 && "$OLD" != null ]] || { err 'Usage: hy2-limit set Mbps (requires prior HY2 install)'; return 1; }
      current_hy2 || return 1
      change true "$2" "${VPS_SHAPING_INTERFACE:-$(jq -r .iface <<< "$OLD")}" "$(jq -r .port <<< "$OLD")" ;;
    off|disable-all)
      [[ $# == 1 ]] || return 1
      [[ "$OLD" != null ]] || return 0
      if [[ "$cmd" == disable-all ]]; then NEW_HOP='{"mode":"external","ports":[],"iface":""}'; fi
      change false "$(jq -r .mbps <<< "$OLD")" "$(jq -r .iface <<< "$OLD")" "$(jq -r .port <<< "$OLD")" ;;
    configure)
      [[ ( $# == 6 || $# == 7 ) && ( "$2" == true || "$2" == false ) && "$6" == /* && "$6" != *$'\n'* ]] || return 1
      CONFIG_PATH=$6
      NEW_HOP=${7:-'{"mode":"external","ports":[],"iface":""}'}
      local prior=$HOP; HOP=$NEW_HOP; local check_old=$OLD; OLD=$(jq -cn --argjson h "$HOP" '{hop:$h}'); hop_load || return 1; OLD=$check_old; HOP=$prior
      change "$2" "$3" "$4" "$5" ;;
    restore)
      [[ "$OLD" != null ]] || return 0
      current_hy2 || return 1
      choose_iface "$(jq -r .iface <<< "$OLD")" || return 1
      if [[ $(jq -r .mode <<< "$HOP") == local ]]; then local shape=$IFACE; choose_iface "$(jq -r .iface <<< "$HOP")" || return 1; IFACE=$shape; fi
      if [[ $(jq -r .mode <<< "$HOP") == local ]]; then PORT=$(jq -r .port <<< "$OLD"); nat_apply || return 1; fi
      [[ $(jq -r .enabled <<< "$OLD") == true ]] || return 0
      no_local_nat || return 1
      if [[ -e "$LIVE" ]] && owned 2>/dev/null; then return 0; fi
      # A new boot discards volatile live fingerprints, NEVER delete unknown rules.
      default_queue || return 1
      rm -f "$LIVE"
      change true "$(jq -r .mbps <<< "$OLD")" "$IFACE" "$(jq -r .port <<< "$OLD")" ;;
    *) err 'Usage: hy2-limit status | set Mbps | off' ;;
  esac
}
main "$@"
HY2_LIMIT_HELPER
  cat > "$WORK_DIR/hy2-limit.service" <<'HY2_LIMIT_SYSTEMD'
# hy2-limit v1 -- installer-owned
[Unit]
Description=HY2-only aggregate UDP egress limit
After=network-online.target
Wants=network-online.target
Before=sing-box.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hy2-limit restore
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
HY2_LIMIT_SYSTEMD
  cat > "$WORK_DIR/hy2-limit.conf" <<'HY2_LIMIT_DROPIN'
# hy2-limit v1 -- installer-owned
[Unit]
Requires=hy2-limit.service
After=hy2-limit.service
[Service]
ExecStartPre=/usr/local/sbin/hy2-limit restore
HY2_LIMIT_DROPIN
  cat > "$WORK_DIR/hy2-limit.openrc" <<'HY2_LIMIT_OPENRC'
#!/sbin/openrc-run
# hy2-limit v1 -- installer-owned
name="hy2-limit"
description="HY2-only aggregate UDP egress limit"
depend() { need net; before sing-box; }
start() { /usr/local/sbin/hy2-limit restore; }
stop() { return 0; }
HY2_LIMIT_OPENRC
  cat > "$WORK_DIR/hy2-limit.wrapper" <<'HY2_LIMIT_WRAPPER'
#!/bin/sh
# hy2-limit v1 -- installer-owned
exec /usr/local/sbin/hy2-limit "$@"
HY2_LIMIT_WRAPPER
  HY2_LIMIT_NEW_FILES=''
  HY2_LIMIT_INIT_OLD=absent
  if [[ "$HY2_LIMIT_INIT" == openrc && -e /etc/init.d/sing-box ]]; then
    [[ ! -L /etc/init.d/sing-box ]] || { fail 'Refusing symlink OpenRC sing-box unit during HY2 limiter integration'; return 1; }
    cp -p /etc/init.d/sing-box "$WORK_DIR/sing-box.openrc.previous" || return 1
    HY2_LIMIT_INIT_OLD=present
  fi
  # Resolve the hopping interface using the SAME audited default-route selection.
  HY2_LIMIT_HOP='{"mode":"external","ports":[],"iface":""}'
  if [[ ${HY2_PORT_HOPPING_MODE:-external} == local ]]; then
    local hop_iface
    hop_iface=$(bash "$WORK_DIR/hy2-limit" probe-interface "${HY2_HOPPING_INTERFACE:-${VPS_SHAPING_INTERFACE:-}}") || return 1
    HY2_LIMIT_IFACE=${HY2_LIMIT_IFACE:-$hop_iface}
    HY2_LIMIT_HOP=$(jq -cn --arg i "$hop_iface" --argjson p "$HY2_INTERVALS_JSON" '{mode:"local",ports:$p,iface:$i}') || return 1
  fi
  hy2_limit_file "$WORK_DIR/hy2-limit" /usr/local/sbin/hy2-limit 700 || return 1
  hy2_limit_file "$WORK_DIR/hy2-limit.wrapper" /usr/local/bin/hy2-limit 755 || return 1
  if [[ "$HY2_LIMIT_INIT" == systemd ]]; then
    mkdir -p /etc/systemd/system/sing-box.service.d
    hy2_limit_file "$WORK_DIR/hy2-limit.service" /etc/systemd/system/hy2-limit.service 644 || return 1
    hy2_limit_file "$WORK_DIR/hy2-limit.conf" /etc/systemd/system/sing-box.service.d/hy2-limit.conf 644 || return 1
    systemctl daemon-reload && systemctl enable hy2-limit.service || return 1
  else
    hy2_limit_file "$WORK_DIR/hy2-limit.openrc" /etc/init.d/hy2-limit 755 || return 1
    rc-update add hy2-limit default || return 1
    HY2_RC_DEP=hy2-limit
  fi
}

hy2_limit_file() {
  local src=$1 dest=$2 mode=$3
  if [[ -e "$dest" || -L "$dest" ]]; then
    [[ ! -L "$dest" && -f "$dest" && $(stat -c %u "$dest") == 0 && $(stat -c %a "$dest") == "$mode" ]] || { fail "HY2 limiter path conflict: $dest"; return 1; }
    if ! cmp -s "$src" "$dest"; then
      # Only the COMPLETE shipped v1 payload is accepted, never a header substring.
      local digest backup
      [[ "$dest" == /usr/local/sbin/hy2-limit ]] || { fail "Unknown HY2 unit/file: $dest"; return 1; }
      hy2_limit_ensure_tools sha256sum || return 1
      digest=$(sha256sum "$dest"); digest=${digest%% *}
      [[ "$digest" == e6f02788c839bdaa528e156fb070856e18c829a3920f7da18b1b1e7e6e204474 ]] || { fail 'Unknown HY2 helper; refusing overwrite'; return 1; }
      backup=$(mktemp "$dest.v1.XXXXXX") || return 1
      cp -p "$dest" "$backup" || return 1
      HY2_LIMIT_UPGRADE_BACKUP=$backup
      install -m "$mode" "$src" "$dest" || return 1
    fi
  else
    install -m "$mode" "$src" "$dest" || return 1
    HY2_LIMIT_NEW_FILES+="$dest "
  fi
}

hy2_limit_apply() {
  [[ "${HY2_LIMIT_ACTIVE:-0}" == 1 ]] || return 0
  HY2_LIMIT_APPLY_ATTEMPTED=1
  /usr/local/sbin/hy2-limit configure "$HY2_LIMIT_ENABLED" "$HY2_LIMIT_MBPS" "$HY2_LIMIT_IFACE" "$HY2_LISTEN_PORT" "$CONFIG_FILE" "$HY2_LIMIT_HOP" || return 1
  HY2_LIMIT_CHANGED=1
}

hy2_limit_verify() {
  [[ "${HY2_LIMIT_ACTIVE:-0}" == 1 ]] || return 0
  /usr/local/sbin/hy2-limit status || { fail 'HY2 limiter protection is missing/modified; installation NOT accepted'; return 1; }
}

hy2_limit_rollback() {
  if [[ "${HY2_LIMIT_DETACHED:-0}" == 1 ]]; then
    cp -p "$WORK_DIR/dropin.previous" /etc/systemd/system/sing-box.service.d/hy2-limit.conf && systemctl daemon-reload || _warn2 'Could not restore HY2 drop-in'
    HY2_LIMIT_DETACHED=0
  fi
  [[ "${HY2_LIMIT_ACTIVE:-0}" == 1 ]] || return 0
  local restored=1 p actual
  if [[ "${HY2_LIMIT_APPLY_ATTEMPTED:-0}" == 1 && "${HY2_LIMIT_CHANGED:-0}" != 1 ]]; then
    actual=$(jq -cS . /etc/hy2-limit/state.json 2>/dev/null) || actual=null
    if [[ "$actual" != "$(jq -cS . <<< "$HY2_LIMIT_OLD")" ]]; then HY2_LIMIT_CHANGED=1
    elif [[ "$HY2_LIMIT_OLD" != null && $(jq -r .enabled <<< "$HY2_LIMIT_OLD") == true ]]; then
      /usr/local/sbin/hy2-limit status >/dev/null || restored=0
    fi
  fi
  if [[ "${HY2_LIMIT_CHANGED:-0}" == 1 ]]; then
    if [[ "$HY2_LIMIT_OLD" == null ]]; then
      /usr/local/sbin/hy2-limit disable-all && rm -f /etc/hy2-limit/state.json /etc/hy2-limit/nat.json || restored=0
    else
      /usr/local/sbin/hy2-limit configure "$(jq -r .enabled <<< "$HY2_LIMIT_OLD")" "$(jq -r .mbps <<< "$HY2_LIMIT_OLD")" "$(jq -r .iface <<< "$HY2_LIMIT_OLD")" "$(jq -r .port <<< "$HY2_LIMIT_OLD")" "$(jq -r --arg c "$CONFIG_FILE" '.config // $c' <<< "$HY2_LIMIT_OLD")" "$(jq -c '.hop // {mode:"external",ports:[],iface:""}' <<< "$HY2_LIMIT_OLD")" || restored=0
      [[ "$restored" != 1 ]] || printf '%s\n' "$HY2_LIMIT_OLD" > /etc/hy2-limit/state.json
    fi
  fi
  if [[ "${HY2_LIMIT_APPLY_ATTEMPTED:-0}" == 1 && "${HY2_LIMIT_CHANGED:-0}" != 1 && "$HY2_LIMIT_OLD" == null ]]; then
    # Retain the independent recovery tools on an uncertain first enable failure.
    restored=0
    if [[ -e /run/hy2-limit-live.json ]]; then HY2_LIMIT_RECOVERY_FAILED=1; fi
  fi
  if [[ "$restored" == 1 ]]; then
    if [[ -n ${HY2_LIMIT_UPGRADE_BACKUP:-} ]]; then cp -p "$HY2_LIMIT_UPGRADE_BACKUP" /usr/local/sbin/hy2-limit || return 1; fi
    if [[ " ${HY2_LIMIT_NEW_FILES:-}" == *' /etc/systemd/system/hy2-limit.service '* ]]; then systemctl disable hy2-limit.service || true; fi
    if [[ " ${HY2_LIMIT_NEW_FILES:-}" == *' /etc/init.d/hy2-limit '* ]]; then rc-update del hy2-limit default || true; fi
    for p in ${HY2_LIMIT_NEW_FILES:-}; do rm -f "$p"; done
    [[ "${HY2_LIMIT_INIT:-}" != systemd ]] || systemctl daemon-reload || true
  elif [[ "$restored" != 1 ]]; then
    HY2_LIMIT_RECOVERY_FAILED=1
    _warn2 'CRITICAL: HY2 limiter rollback failed; preserved helper/state/rules; stopping sing-box until repaired.'
    if _cmd systemctl && [[ -d /run/systemd/system ]]; then systemctl stop sing-box || true
    elif _cmd rc-service; then rc-service sing-box stop || true; fi
  fi
  HY2_LIMIT_CHANGED=0
  if [[ "${HY2_LIMIT_INIT:-}" == openrc && "${HY2_LIMIT_INIT_OLD:-}" == present && -f "${WORK_DIR:-}/sing-box.openrc.previous" ]]; then
    cp -p "$WORK_DIR/sing-box.openrc.previous" /etc/init.d/sing-box || _warn2 'Could not restore prior OpenRC sing-box unit'
  fi
}

cleanup_installer() {
  local status=$?
  trap - EXIT
  if [[ "${CONFIG_ACCEPTED:-0}" != 1 ]]; then hy2_limit_rollback || true; fi
  if [[ "${CONFIG_COMMITTED:-0}" == 1 && "${CONFIG_ACCEPTED:-0}" != 1 ]]; then rollback_config || true; fi
  [[ -z "${WORK_DIR:-}" ]] || rm -rf "$WORK_DIR"
  exit "$status"
}

restart_detached() {
  # Restore any unaccepted config before re-execution rotates node credentials.
  trap '' HUP
  if [[ "${CONFIG_ACCEPTED:-0}" != 1 ]]; then hy2_limit_rollback || true; fi
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
  hy2_limit_prepare
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
  hy2_limit_install
  hy2_limit_apply
  commit_candidate "$WORK_DIR/config.json"
  if ! start_service; then fail 'Service start failed; restoring previous configuration'; return 1; fi
  if ! self_check; then fail 'Protocol self-check failed; restoring previous configuration'; return 1; fi
  hy2_limit_verify
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
