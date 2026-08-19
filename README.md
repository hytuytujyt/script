# install_reality.sh — VLESS+Reality / Shadowsocks 节点一键安装脚本

单文件自举版，一条命令完成节点部署。兼容 **Alpine / Debian / Ubuntu / Fedora / CentOS / openSUSE** 等主流发行版，内核（xray / sing-box）自动选择。

支持两种角色：

| MODE | 角色 | 协议 |
|------|------|------|
| `relay`（默认）| 中转节点 | VLESS + Reality |
| `landing` | 落地节点 | Shadowsocks（经典 aes-128-gcm）|

---

## 断线免疫与内核自适应（无需配置，自动生效）

> **断线免疫（v3 新增）**：平时**完全按原设计前台执行**（实时输出、私钥打印一次即删、"输入 yes 关密码登录"交互全部照旧）。只有 SSH 连接**断开的一瞬间**，脚本自动转入后台续跑（幂等，从断点继续），日志在 `/root/install_reality.log`（`INSTALL_LOG` 可覆盖），重连后 `tail -f /root/install_reality.log` 查看进度。后台续跑时：**不自动关闭密码登录**（防锁死），私钥保留在 `/root/.ssh/id_ed25519`；重连后执行 **`sshkey`** 一键完成"查看私钥（查看后自动删除）+ 自动检查/关闭密码登录"。

> **内核自适应**：脚本自动检测 `/tmp` 是否为内存盘（tmpfs）——是则用 **xray**（二进制约 sing-box 一半，小内存容器能装），否则用 **sing-box**。全程无需干预，两种内核产出的客户端链接格式完全一致。

---

## 情况一：VLESS Reality 中转节点（默认 relay）

```
if command -v wget >/dev/null 2>&1; then wget -qO- https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh; elif command -v curl >/dev/null 2>&1; then curl -fsSL https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh; elif command -v busybox >/dev/null 2>&1; then busybox wget -qO- https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh; else echo '需要 wget/curl/busybox 之一' >&2; exit 1; fi | ACTUAL_LISTEN_PORT=a LISTEN_PORT=b SERVER_IP=y NODE_NAME=z sh
```

| 环境变量 | 含义 | 示例 |
|----------|------|------|
| `ACTUAL_LISTEN_PORT=a` | **实际监听端口**：服务端真正监听的口（写进 config.json 的 `listen_port`）。填商家放行给你的端口 | `ACTUAL_LISTEN_PORT=2053` |
| `LISTEN_PORT=b` | **输出/映射端口**：写进 vless 链接与防火墙的口。NAT 机器填映射后的外部端口；非 NAT 填与实际监听相同即可 | `LISTEN_PORT=62879` 或 `LISTEN_PORT=2053` |
| `SERVER_IP=y` | 服务器的公网 IP | `SERVER_IP=45.207.35.102` |
| `NODE_NAME=z` | 节点名（YAML 与 vless 链接里显示，可带 emoji）名字中间不能有空格，赋值错误导致整个命令失效| `NODE_NAME=lzycat🇯🇵` |

---

## 情况二：Shadowsocks 落地节点（MODE=landing）

```
if command -v wget >/dev/null 2>&1; then wget -qO- https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh; elif command -v curl >/dev/null 2>&1; then curl -fsSL https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh; elif command -v busybox >/dev/null 2>&1; then busybox wget -qO- https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh; else echo '需要 wget/curl/busybox 之一' >&2; exit 1; fi | MODE=landing ACTUAL_LISTEN_PORT=a LISTEN_PORT=b SERVER_IP=y NODE_NAME=z sh
```

| 环境变量 | 含义 | 示例 |
|----------|------|------|
| `ACTUAL_LISTEN_PORT=a` | **实际监听端口**：服务端真正监听的口（写进 config.json 的 `listen_port`）。填服务商放行给你的固定端口 | `ACTUAL_LISTEN_PORT=23061` |
| `LISTEN_PORT=b` | **输出/映射端口**：写进 ss:// 链接与防火墙的口。非 NAT 填与实际监听相同即可 | `LISTEN_PORT=23061` |
| `SERVER_IP=y` | 服务器的公网 IP | `SERVER_IP=45.207.35.102` |
| `NODE_NAME=z` | 节点名（ss:// 链接 `#` 后显示，可带 emoji）| `NODE_NAME=uzuma` |

---

## 其他可选环境变量

> 注意：`ACTUAL_LISTEN_PORT`、`LISTEN_PORT`、`SERVER_IP` 是**必填**（见上方表格），不在下面的可选列表里。

| 环境变量 | 含义 | 示例 |
|----------|------|------|
| `REALITY_DEST` | Reality 伪装握手目标（默认 `addons.mozilla.org:443`）| `REALITY_DEST=www.microsoft.com:443` |
| `REALITY_SERVER_NAME` | 客户端 SNI / server_name（默认 `addons.mozilla.org`）| `REALITY_SERVER_NAME=www.microsoft.com` |
| `SS_METHOD` | Shadowsocks 加密方式（默认 `aes-128-gcm`，兼容性最好）| `SS_METHOD=aes-256-gcm` |
| `SS_PASSWORD` | Shadowsocks 密码，不设则自动随机生成 | `SS_PASSWORD=mysecret123` |
| `SSH_KEY_REGENERATE` | 设为 `1` 强制重新生成 SSH 密钥（私钥丢失时用）| `SSH_KEY_REGENERATE=1` |
| `SSH_KEY_DELETE` | 设为 `1` 强制"打印一次即删"（含断连转后台续跑场景，风险自负）；默认前台打印即删、后台续跑时保留在 `/root/.ssh/id_ed25519` | `SSH_KEY_DELETE=1` |
| `SCRIPT_URL` | 管道模式下载脚本的地址覆盖 | `SCRIPT_URL=https://example.com/install.sh` |
| `INSTALL_LOG` | 断连转后台续跑时的安装日志路径（默认 `/root/install_reality.log`）| `INSTALL_LOG=/root/my.log` |
| `LISTEN_ADDR` | 监听地址，默认 `0.0.0.0`（纯 IPv4 最稳）；双栈机器可改 `::` | `LISTEN_ADDR=0.0.0.0` |

---

## 端口逻辑

两种模式统一，**两个端口都必填、都由你显式指定**（不做"0=默认"回退）：

- **`ACTUAL_LISTEN_PORT`（实际监听端口）**：写进 `config.json` 的 `listen_port`，是服务端真正监听的端口。
- **`LISTEN_PORT`（输出/映射端口）**：写进 vless/ss 链接与防火墙放行的端口。

两者互不绑定，各自独立设置：

| 场景 | ACTUAL_LISTEN_PORT | LISTEN_PORT |
|------|--------------------|-------------|
| 非 NAT（常见） | 商家放行的端口，如 `2053` | 填一样，如 `2053` |
| NAT 机器 | 内部实际监听，如 `2053` | 映射后的外部端口，如 `62879` |
| 端口不限的商家 | 任意，如 `443` | 填一样，如 `443` |

> `ACTUAL_LISTEN_PORT` 与 `LISTEN_PORT` 相同时只填一个也行？——不行，**两个都必须填**。不填脚本会报错退出，这是有意为之：宁可让你明说，也不猜。

---

## 功能清单

| 功能 | 说明 | 通用/分模式 |
|------|------|------------|
| **自动补齐依赖** | 引导段检测 `bash`/`curl`，缺失则按包管理器自动安装（apk/apt/dnf/yum/zypper/pacman）| 通用 |
| **单文件自举** | 管道执行时自动下载正文交 bash 运行 | 通用 |
| **断线免疫** | 平时前台正常执行；SSH 断开瞬间捕获 SIGHUP 自动转入后台续跑（幂等），日志 `/root/install_reality.log` | 通用 |
| **内核自适应** | 自动检测：`/tmp` 为内存盘（tmpfs）时用 **xray**（二进制约 sing-box 一半，小内存容器能装）；否则用 **sing-box**。对使用端完全无感，客户端链接格式一致 | 通用 |
| **稳健下载** | 下载 xray/sing-box 支持**断点续传**（`curl -C -`）+ 最多 5 次自动重试，应对 NAT 机器慢速/网关重置下载 | 通用 |
| **安装 sing-box** | 官方静态二进制 tar.gz（优先 -musl），幂等：已装且可运行则跳过；**落盘 md5/大小校验 + 失败自动重试 3 次** | 非 tmpfs 机器 |
| **安装 xray** | 官方 zip（Xray-core latest），架构自动映射，幂等 + 落盘校验 | tmpfs 机器 |
| **架构自适应** | x86_64 / arm64 / 386 / armv7 / riscv64 / s390x 自动映射（两套内核命名各自映射）| 通用 |
| **生成 Reality 身份** | reality-keypair 密钥对 + UUID + short_id | relay |
| **生成 SS 凭据** | 随机 base64 密码 + aes-128-gcm 加密方式 | landing |
| **写服务端配置** | relay 写 VLESS+Reality；landing 写 Shadowsocks → `/etc/sing-box/config.json` | 分模式 |
| **防火墙放行** | 自动放行端口（ufw / firewalld），并提示 iptables 拒绝规则 | 通用 |
| **启动服务** | 自动识别 systemd / openrc（Alpine 缺 openrc 时自动补装），创建服务定义并开机自启 | 通用 |
| **日志轮转** | logrotate 单文件 >10M 或每日轮转，保留 3 份压缩（Alpine 额外写入 crond）| 通用 |
| **输出连接信息** | relay 输出 vless 链接 + JSON + YAML；landing 只输出 ss://。存档 `/etc/sing-box/node_output.txt` | 分模式 |
| **服务端自检** | 安装完成后用同款内核起临时客户端，本机直连验证 Reality 握手 + 出站（Google 204）；只验证服务端，外部 NAT 映射需客户端实测 | 通用 |
| **shownode 快捷指令** | `shownode` 一键查看节点连接信息 | 通用 |
| **sshkey 快捷指令** | 重连后执行 `sshkey`：查看 SSH 私钥（**查看后自动删除**）+ **自动检查密码登录**（没关就自动关闭并校验，已关则提示）；`sshkey --check` 只检查不修改（`showsshkey` 是它的别名）| 通用 |
| **log 快捷指令** | `log` 查看最近 100 行日志 + 轮转档案 | 通用 |
| **生成 SSH ed25519 密钥** | 公钥入 `authorized_keys`；**前台正常执行：私钥打印一次即删（原设计）**；断连转后台续跑时才保留在 `/root/.ssh/id_ed25519`（权限600），重连后 `sshkey` 查看（查看后自动删除）| 通用 |
| **关闭密码登录** | 前台交互式：现场验证 `sshd -T` 为 `no` 后输入 `yes` 才生效；**断连后台续跑时不自动关闭**（保持密码登录防锁死），重连后执行 `sshkey` 自动检查并关闭 | 通用 |

---

## 交互确认：关闭密码登录

脚本运行到末尾会停下，提示你**先到另一个 SSH 窗口验证**：

```
sshd -T | grep -iE 'password|kbdinteractive|challengeresponse'
```

关键项 `PasswordAuthentication` 必须为 `no` 后，回来输入 `yes` 回车，脚本才真正关闭密码登录并重启 sshd。输入其他内容则跳过、保持密码登录开启。

> 安全兜底：`authorized_keys` 中无公钥时自动跳过，绝不锁死自己。
> 注意：**交互需要真实终端**。前台正常执行时照常交互（`/dev/tty` 读取，管道方式也能用）。**断连转后台续跑时**没有终端：脚本**不自动关闭密码登录**（保持现状，防锁死）；重连后执行 `sshkey`，它会显示私钥（查看后自动删除）并自动检查密码登录——没关就自动关闭（带 `authorized_keys` 校验），已关就提示一下。

---

## 使用注意

1. **`SERVER_IP`、`ACTUAL_LISTEN_PORT`、`LISTEN_PORT` 必填**，缺任何一个脚本都会退出。`ACTUAL_LISTEN_PORT` 是 config.json 的实际监听端口；`LISTEN_PORT` 是链接/防火墙用的输出端口。
2. **端口以商家放行为准**：`ACTUAL_LISTEN_PORT` 必须填商家实际放行给你监听的端口，否则服务端监听的口连不通。NAT 场景再额外用 `LISTEN_PORT` 填映射后的外部端口。
3. **私钥**：前台正常执行 = 打印一次即删（原设计），请立即存入 Termius；若中途断连转后台续跑，私钥保留在 `/root/.ssh/id_ed25519`（权限600），重连后执行 `sshkey` 查看——**查看后自动删除**（对齐"服务器不留私钥"），并请清理安装日志里的私钥段。`sshkey` 同时会自动检查/关闭密码登录（未关则自动关闭并校验，已关则提示）；`sshkey --check` 可只查不改。
4. **小内存机器**：sing-box 仅占几十 MB，200MB 配额足够；面板显示的高占用多为文件缓存，无需处理。**注意**：部分容器（尤其 NAT 小鸡）的 `/tmp` 是内存盘（tmpfs），解压 68MB 的 sing-box 会占用容器内存配额导致卡顿断连——脚本会自动检测并改用 xray（体积小一半），无需手动干预。
5. **关闭密码登录前**：确保新的 SSH 私钥已保存，再输入 `yes`，避免锁死。
6. **服务端自检 vs NAT 映射**：脚本装完会本机自检（验证服务端 Reality + 出站）。自检通过但你外部连不上 → 问题在 NAT 映射（外部端口是否映射到这台机器），查服务商面板。

---

## 输出文件与路径

| 路径 | 内容 |
|------|------|
| `/etc/sing-box/config.json` 或 `/usr/local/etc/xray/config.json` | 服务端配置（按内核）|
| `/etc/sing-box/node_output.txt` | 节点连接信息（vless/ss 链接）|
| `/var/log/sing-box.log` 或 `/var/log/xray.log` | 运行日志（按内核）|
| `/etc/logrotate.d/sing-box` 或 `/etc/logrotate.d/xray` | 日志轮转规则（按内核）|
| `/etc/systemd/system/sing-box.service`、`/etc/init.d/sing-box` 或对应 xray 版 | 服务定义（按系统/内核）|
| `/etc/ssh/sshd_config.d/00-disable-password.conf` | 关闭密码登录 drop-in（执行后）|
| `/root/.ssh/id_ed25519`（及 `.pub`）| SSH 私钥（断连转后台续跑时保留，权限600）与公钥 |
| `/usr/local/bin/sshkey` | `sshkey` 命令本体（查看私钥 + 自动检查/关闭密码登录）|
