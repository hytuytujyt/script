#!/usr/bin/env bash
set -euo pipefail

### 可通过环境变量覆盖的配置 ###
# LISTEN_PORT=0        表示非NAT机器，内网/外部都用443
# LISTEN_PORT=xxxxx    表示NAT机器，NAT映射到内部443端口的外部端口号是xxxxx
LISTEN_PORT="${LISTEN_PORT:-0}"
SERVER_LISTEN_PORT=443                                        # sing-box 实际监听端口，恒定443
REALITY_DEST="${REALITY_DEST:-www.microsoft.com:443}"        # 伪装握手目标
REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-www.microsoft.com}"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"

### 根据 LISTEN_PORT 判断输出端口 ###
if [ "$LISTEN_PORT" -eq 0 ]; then
  OUTPUT_PORT=$SERVER_LISTEN_PORT
else
  OUTPUT_PORT=$LISTEN_PORT
fi

### 1. 安装 sing-box（幂等，已装则跳过）###
install_singbox() {
  if command -v sing-box >/dev/null 2>&1; then
    echo "[*] sing-box 已安装，跳过"
    return
  fi
  echo "[*] 安装 sing-box ..."
  bash <(curl -fsSL https://sing-box.app/install.sh)
}

### 2. 生成密钥 / UUID / short_id ###
generate_credentials() {
  echo "[*] 生成 Reality 密钥对与身份信息 ..."
  local key_output
  key_output=$(sing-box generate reality-keypair)
  PRIVATE_KEY=$(echo "$key_output" | awk '/PrivateKey/ {print $2}')
  PUBLIC_KEY=$(echo "$key_output" | awk '/PublicKey/ {print $2}')
  UUID=$(sing-box generate uuid)
  SHORT_ID=$(sing-box generate rand 8 --hex)
}

### 3. 写入服务端配置文件（监听端口恒定443）###
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

### 4. 启动服务（自动识别 systemd / openrc） ###
start_service() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable sing-box && systemctl restart sing-box
  elif command -v rc-service >/dev/null 2>&1; then
    rc-update add sing-box default && rc-service sing-box restart
  else
    echo "[!] 未识别到 systemd/openrc，请手动启动 sing-box"
  fi
}

### 5. 输出 vless 链接 + 客户端 config.json（不生成二维码） ###
print_result() {
  # 这里的 IP 必须是客户端实际拨号连接的公网入口IP，NAT机器出网IP可能与之不同，不一致时用 SERVER_IP 覆盖
  local ip="${SERVER_IP:-$(curl -s4 ifconfig.me || curl -s6 ifconfig.me)}"
  local link="vless://${UUID}@${ip}:${OUTPUT_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#reality-$(hostname)"

  echo ""
  echo "================ VLESS 链接 ================"
  echo "$link"

  echo ""
  echo "============ 客户端 config.json ============"
  cat <<EOF
{
  "outbounds": [
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
  ]
}
EOF
  echo "=============================================="
}

install_singbox
generate_credentials
write_config
start_service
print_result
