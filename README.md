# install_reality.sh — sing-box 节点一键安装脚本

单文件自举版，一条命令完成 sing-box 节点部署。兼容 **Alpine / Debian / Ubuntu / Fedora / CentOS / openSUSE** 等主流发行版。

支持两种角色：

| MODE | 角色 | 协议 |
|------|------|------|
| `relay`（默认）| 中转节点 | VLESS + Reality |
| `landing` | 落地节点 | Shadowsocks（经典 aes-128-gcm）|

---

## 一键命令（模板）

复制下面**一整行**粘贴执行即可（GitHub 直拉 + 环境变量注入，不会被换行符打断）：

```
{ command -v wget >/dev/null 2>&1 && wget -qO- https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh || command -v curl >/dev/null 2>&1 && curl -fsSL https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh || command -v busybox >/dev/null 2>&1 && busybox wget -qO- https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh ; } | LISTEN_PORT=x SERVER_IP=y NODE_NAME=z sh
```

下面按模式告诉你 x / y / z 分别填什么。

---

## 情况一：VLESS Reality 中转节点（默认 relay）

```
{ command -v wget >/dev/null 2>&1 && wget -qO- https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh || command -v curl >/dev/null 2>&1 && curl -fsSL https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh || command -v busybox >/dev/null 2>&1 && busybox wget -qO- https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh ; } | LISTEN_PORT=x SERVER_IP=y NODE_NAME=z sh
```

| 环境变量 | 含义 | 示例 |
|----------|------|------|
| `LISTEN_PORT=x` | NAT 机器：填映射后的外部端口号；非 NAT 或 IPv6-only 填 `0`（自动用 443）| `LISTEN_PORT=62879` 或 `LISTEN_PORT=0` |
| `SERVER_IP=y` | 服务器的公网 IP | `SERVER_IP=45.207.35.102` |
| `NODE_NAME=z` | 节点名（YAML 与 vless 链接里显示，可带 emoji）| `NODE_NAME=lzycat🇯🇵` |

---

## 情况二：Shadowsocks 落地节点（MODE=landing）

```
{ command -v wget >/dev/null 2>&1 && wget -qO- https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh || command -v curl >/dev/null 2>&1 && curl -fsSL https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh || command -v busybox >/dev/null 2>&1 && busybox wget -qO- https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh ; } | MODE=landing LISTEN_PORT=x SERVER_IP=y NODE_NAME=z sh
```

| 环境变量 | 含义 | 示例 |
|----------|------|------|
| `LISTEN_PORT=x` | **服务商放行给你的固定端口**（如 23061、36954）；服务商不限端口填 `0`（自动用 8388）。服务端监听、防火墙、ss:// 链接都会用这个端口 | `LISTEN_PORT=23061` 或 `LISTEN_PORT=0` |
| `SERVER_IP=y` | 服务器的公网 IP | `SERVER_IP=45.207.35.102` |
| `NODE_NAME=z` | 节点名（ss:// 链接 `#` 后显示，可带 emoji）| `NODE_NAME=uzuma` |

---

## 其他可选环境变量

| 环境变量 | 含义 | 示例 |
|----------|------|------|
| `REALITY_DEST` | Reality 伪装握手目标（默认 `addons.mozilla.org:443`）| `REALITY_DEST=www.microsoft.com:443` |
| `REALITY_SERVER_NAME` | 客户端 SNI / server_name（默认 `addons.mozilla.org`）| `REALITY_SERVER_NAME=www.microsoft.com` |
| `SS_METHOD` | Shadowsocks 加密方式（默认 `aes-128-gcm`，兼容性最好）| `SS_METHOD=aes-256-gcm` |
| `SS_PASSWORD` | Shadowsocks 密码，不设则自动随机生成 | `SS_PASSWORD=mysecret123` |
| `SSH_KEY_REGENERATE` | 设为 `1` 强制重新生成 SSH 密钥（私钥丢失时用）| `SSH_KEY_REGENERATE=1` |
| `SCRIPT_URL` | 管道模式下载脚本的地址覆盖 | `SCRIPT_URL=https://example.com/install.sh` |

---

## 端口逻辑

- **relay**：服务端实际监听恒定 `443`。`LISTEN_PORT=0` → 链接/防火墙用 `443`；填了映射端口 → 链接/防火墙用该端口（NAT 场景）。
- **landing**：服务端监听 = `LISTEN_PORT`（服务商固定端口必填），填 `0` 默认 `8388`。配置、防火墙、ss:// 链接三者始终一致。

---

## 功能清单

| 功能 | 说明 | 通用/分模式 |
|------|------|------------|
| **自动补齐依赖** | 引导段检测 `bash`/`curl`，缺失则按包管理器自动安装（apk/apt/dnf/yum/zypper/pacman）| 通用 |
| **单文件自举** | 管道执行时自动下载正文交 bash 运行 | 通用 |
| **安装 sing-box** | 官方静态二进制 tar.gz（优先 -musl），幂等：已装且可运行则跳过 | 通用 |
| **架构自适应** | x86_64 / arm64 / 386 / armv7 / riscv64 / s390x 自动映射 | 通用 |
| **生成 Reality 身份** | reality-keypair 密钥对 + UUID + short_id | relay |
| **生成 SS 凭据** | 随机 base64 密码 + aes-128-gcm 加密方式 | landing |
| **写服务端配置** | relay 写 VLESS+Reality；landing 写 Shadowsocks → `/etc/sing-box/config.json` | 分模式 |
| **防火墙放行** | 自动放行端口（ufw / firewalld），并提示 iptables 拒绝规则 | 通用 |
| **启动服务** | 自动识别 systemd / openrc，创建服务定义并开机自启 | 通用 |
| **日志轮转** | logrotate 单文件 >10M 或每日轮转，保留 3 份压缩（Alpine 额外写入 crond）| 通用 |
| **输出连接信息** | relay 输出 vless 链接 + JSON + YAML；landing 只输出 ss://。存档 `/etc/sing-box/node_output.txt` | 分模式 |
| **shownode 快捷指令** | `shownode` 一键查看节点连接信息 | 通用 |
| **log 快捷指令** | `log` 查看最近 100 行日志 + 轮转档案 | 通用 |
| **生成 SSH ed25519 密钥** | 公钥入 `authorized_keys`，私钥终端打印一次后删除 | 通用 |
| **关闭密码登录** | 交互式：现场验证 `sshd -T` 为 `no` 后输入 `yes` 才生效；`/dev/tty` 读取，管道模式也能交互 | 通用 |

---

## 交互确认：关闭密码登录

脚本运行到末尾会停下，提示你**先到另一个 SSH 窗口验证**：

```
sshd -T | grep -iE 'password|kbdinteractive|challengeresponse'
```

关键项 `PasswordAuthentication` 必须为 `no` 后，回来输入 `yes` 回车，脚本才真正关闭密码登录并重启 sshd。输入其他内容则跳过、保持密码登录开启。

> 安全兜底：`authorized_keys` 中无公钥时自动跳过，绝不锁死自己。
> 注意：**交互需要真实终端**。`curl ... | sh` 管道也能用（脚本已改读 `/dev/tty`），但本地 `sh install_reality.sh` 最稳。

---

## 使用注意

1. **`SERVER_IP` 必填**，否则脚本退出。
2. **落地节点端口**：服务商只放行固定端口时，`LISTEN_PORT` 必须填那个端口，否则服务端监听的端口连不通。
3. **私钥只打印一次**：SSH 私钥生成后终端显示一次即删除，请立即存入 Termius 等客户端。
4. **小内存机器**：sing-box 仅占几十 MB，200MB 配额足够；面板显示的高占用多为文件缓存，无需处理。
5. **关闭密码登录前**：确保新的 SSH 私钥已保存，再输入 `yes`，避免锁死。

---

## 输出文件与路径

| 路径 | 内容 |
|------|------|
| `/etc/sing-box/config.json` | sing-box 服务端配置 |
| `/etc/sing-box/node_output.txt` | 节点连接信息（vless/ss 链接）|
| `/var/log/sing-box.log` | sing-box 运行日志 |
| `/etc/logrotate.d/sing-box` | 日志轮转规则 |
| `/etc/systemd/system/sing-box.service` 或 `/etc/init.d/sing-box` | 服务定义（按系统）|
| `/etc/ssh/sshd_config.d/00-disable-password.conf` | 关闭密码登录 drop-in（执行后）|
