# bbr_install

> Linux VPS 一键开启 BBR（Google 拥塞控制算法），支持 **Alpine / Debian / Ubuntu** 三种系统。

## 一键安装

复制下面**一整行**粘贴执行即可（GitHub 直拉，自动选择 wget / curl / busybox，不会被换行符打断）：

```
{ command -v wget >/dev/null 2>&1 && wget -qO- https://raw.githubusercontent.com/hytuytujyt/bbr_install/main/install_bbr.sh || command -v curl >/dev/null 2>&1 && curl -fsSL https://raw.githubusercontent.com/hytuytujyt/bbr_install/main/install_bbr.sh || command -v busybox >/dev/null 2>&1 && busybox wget -qO- https://raw.githubusercontent.com/hytuytujyt/bbr_install/main/install_bbr.sh ; } | sh
```

# install_reality.sh — VLESS+Reality / Shadowsocks 节点一键安装脚本

单文件自举版，一条命令完成节点部署。兼容 **Alpine / Debian / Ubuntu / Fedora / CentOS / openSUSE** 等主流发行版，内核（xray / sing-box）自动选择。

支持两种角色：

| MODE | 角色 | 协议 |
|------|------|------|
| `relay`（默认）| 中转节点 | VLESS + Reality |
| `landing` | 落地节点 | Shadowsocks（经典 aes-128-gcm）|

---

## 断线免疫与内核自适应（无需配置，自动生效）

> **断线免疫（v3 新增）**：平时**完全按原设计前台执行**（实时输出、私钥默认保留在服务器）。只有 SSH 连接**断开的一瞬间**，脚本自动转入后台续跑（幂等，从断点继续），日志在 `/root/install_reality.log`（`INSTALL_LOG` 可覆盖），重连后 `tail -f /root/install_reality.log` 查看进度。私钥保留在 `/root/.ssh/id_ed25519`；重连后执行 **`sshkey`** 查看 SSH 私钥（确认保存后才删除）。**关闭密码登录**已从本脚本移除，改放到独立的 bbr 网络加速脚本中（本脚本不再处理密码登录）。

> **内核自适应**：脚本自动检测 `/tmp` 是否为内存盘（tmpfs）——是则用 **xray**（二进制约 sing-box 一半，小内存容器能装），否则用 **sing-box**。全程无需干预，两种内核产出的客户端链接格式完全一致。

---

## 重跑合并：只保留 argo，其余节点替换

脚本**可安全重复运行**，不会误删你自己手动加到服务端的其它节点（如 Cloudflare Argo 隧道节点）。

> 每次运行时，脚本会把服务端配置里的 `inbounds` **只保留 argo 类节点**（vless + websocket transport，或 tag 为 `argo-in`），把其余所有 inbound **全部清除**（包括旧版脚本写的无 tag 的 SS / VLESS Reality，以及任何非 argo 节点），再写入你本次选择分支的节点（relay → VLESS Reality，landing → Shadowsocks）。

即最终配置恒为：`[ argo节点(如有) , 本次所选节点 ]`，其它一律不留。

- **没有 argo 节点不会报错**：一个都不保留时，结果就是干净的单个节点，脚本照常跑完。
- **合并前自动备份**：`/etc/sing-box/config.json.bak.<时间戳>`，想还原可回滚。
- **依赖 `jq`**：脚本会自动按包管理器安装（apk/apt/dnf/yum/zypper/pacman），无需手动处理。
- **兼容旧版脚本**：旧脚本写的无 tag 的 SS / VLESS Reality 节点也会被识别并清除，不会与本次节点冲突。
- **自检仅 relay 模式执行**：`landing`（SS）模式没有 Reality 身份，脚本跳过自检，避免 `UUID: unbound variable` 中断，后面 SSH 密钥/别名/关密码登录仍正常执行。
- **重跑 landing 时 SS 密码会重新随机生成**（除非用 `SS_PASSWORD` 固定），旧 ss:// 链接、`node_output.txt` 会随之更新。

---

## 情况一：VLESS Reality 中转节点（默认 relay）

```
if command -v curl >/dev/null 2>&1; then curl -fL --connect-timeout 10 -m 60 -o /tmp/install_reality.sh https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh; elif command -v wget >/dev/null 2>&1; then wget -q -T 15 -O /tmp/install_reality.sh https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh; elif command -v busybox >/dev/null 2>&1; then busybox wget -q -T 15 -O /tmp/install_reality.sh https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh; else echo '需要 curl/wget/busybox 之一' >&2; exit 1; fi && ACTUAL_LISTEN_PORT=a LISTEN_PORT=b SERVER_IP=y NODE_NAME=z sh /tmp/install_reality.sh
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
if command -v curl >/dev/null 2>&1; then curl -fL --connect-timeout 10 -m 60 -o /tmp/install_reality.sh https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh; elif command -v wget >/dev/null 2>&1; then wget -q -T 15 -O /tmp/install_reality.sh https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh; elif command -v busybox >/dev/null 2>&1; then busybox wget -q -T 15 -O /tmp/install_reality.sh https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh; else echo '需要 curl/wget/busybox 之一' >&2; exit 1; fi && MODE=landing ACTUAL_LISTEN_PORT=a LISTEN_PORT=b SERVER_IP=y NODE_NAME=z sh /tmp/install_reality.sh
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
| `SSH_KEY_REGENERATE` | 设为 `1` 强制重新生成 SSH 密钥。适用于脚本提示"**检测到已有公钥但私钥已不存在（无法恢复）**"的场景（服务器上只剩公钥、私钥已被删、无法找回）| `SSH_KEY_REGENERATE=1` |
| `SSH_KEY_DELETE` | 设为 `1` 强制"打印一次即删"（风险自负）；**默认不删除**，私钥保留在 `/root/.ssh/id_ed25519`（权限600），`sshkey --delete` 可确认后删除 | `SSH_KEY_DELETE=1` |
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
| **重跑合并（保留 argo）** | 每次重跑**只保留 argo 类节点**（vless + websocket transport，或 tag 为 `argo-in`），其余 inbound 全部清除并写入本次所选分支节点；无 argo 不报错；自动备份 `.bak.<时间戳>`；依赖 jq（自动安装）| 通用 |
| **写服务端配置** | relay 写 VLESS+Reality；landing 写 Shadowsocks → `/etc/sing-box/config.json` | 分模式 |
| **防火墙放行** | 自动放行端口（ufw / firewalld），并提示 iptables 拒绝规则 | 通用 |
| **启动服务** | 自动识别 systemd / openrc（Alpine 缺 openrc 时自动补装），创建服务定义并开机自启 | 通用 |
| **日志轮转** | sing-box 分支 logrotate 单文件 >10M 或每日轮转，保留 3 份压缩（Alpine 额外写入 crond）；xray 分支不写日志文件，跳过 | 分模式 |
| **输出连接信息** | relay 输出 vless 链接 + JSON + YAML；landing 只输出 ss://。存档 `/etc/sing-box/node_output.txt` | 分模式 |
| **服务端自检** | 安装完成后用同款内核起临时客户端，本机直连验证 Reality 握手 + 出站（Google 204）；只验证服务端，外部 NAT 映射需客户端实测。**仅 relay（Reality）模式执行，landing（SS）模式跳过** | relay |
| **shownode 快捷指令** | `shownode` 一键查看节点连接信息 | 通用 |
| **sshkey 快捷指令** | 重连后执行 `sshkey`：查看 SSH 私钥（**确认已保存后才删除**，或 `sshkey --delete` 直接删）；`sshkey` 只负责私钥查看/删除，**不处理密码登录**（关闭密码登录已在独立脚本中）| 通用 |
| **log 快捷指令** | `log` 查看最近 100 行日志 + 轮转档案（sing-box 分支）；xray 分支提示"未写日志文件"并显示服务状态 | 分模式 |
| **生成 SSH ed25519 密钥** | 公钥入 `authorized_keys`；**私钥默认保留在服务器** `/root/.ssh/id_ed25519`（权限600），不再自动删除（防丢失锁死）；重连后 `sshkey` 查看，**确认保存后才删**（或 `sshkey --delete` 直接删）；`SSH_KEY_DELETE=1` 可强制打印即删（风险自负）| 通用 |
| **关闭密码登录** | ⚠️ **已从本脚本移除**，改放到独立的 bbr（网络加速）脚本中处理，本脚本不再管理密码登录 | 移出 |

---

## 关闭密码登录（已移出本脚本）

> ⚠️ **本脚本已不再负责关闭密码登录**。该功能已从本脚本移除，改放到你独立的 bbr（网络加速）脚本中处理，二者互不干扰。本脚本只负责：安装代理节点 + 生成/保留 SSH 私钥（`sshkey` 仅查看/确认删除私钥）。
>
> 若你的 bbr 脚本里需要关闭密码登录，请务必先确认服务器上有可用的私钥文件（`/root/.ssh/id_ed25519`）、且你本地已保存好一份对应私钥，再关闭——否则关闭密码后就只能靠私钥验证登录，私钥一丢就锁死。这才是"先确认、再关闭"的安全前提。

---

## 使用注意

1. **`SERVER_IP`、`ACTUAL_LISTEN_PORT`、`LISTEN_PORT` 必填**，缺任何一个脚本都会退出。`ACTUAL_LISTEN_PORT` 是 config.json 的实际监听端口；`LISTEN_PORT` 是链接/防火墙用的输出端口。
2. **端口以商家放行为准**：`ACTUAL_LISTEN_PORT` 必须填商家实际放行给你监听的端口，否则服务端监听的口连不通。NAT 场景再额外用 `LISTEN_PORT` 填映射后的外部端口。
3. **私钥（默认保留，不自动删除）**：脚本生成 ed25519 私钥后**默认保留在服务器** `/root/.ssh/id_ed25519`（权限600），前台和断连续跑都不再自动删除——这样即使你"没有输出/中途断线/没看清屏幕"，私钥也不会永久丢失。这是**防锁死**的关键设计。重连后执行 `sshkey` 查看私钥，**确认已在 Termius 保存后**才删除（会问你输入 `yes` 才删；也可用 `sshkey --delete` 直接删），并请清理安装日志里的私钥段。`sshkey` 只负责私钥查看/删除，**不处理密码登录**（关闭密码登录已放到独立的 bbr 脚本中）。
   > 若脚本提示**"检测到已有公钥但私钥已不存在（无法恢复）"**：说明服务器上只剩公钥（`authorized_keys` 里那条），私钥已被删、无法找回。此时原公钥无法导出对应私钥，用 `SSH_KEY_REGENERATE=1` 重新生成一份新密钥对，并重新保存新的私钥。
4. **小内存机器**：sing-box 仅占几十 MB，200MB 配额足够；面板显示的高占用多为文件缓存，无需处理。**注意**：部分容器（尤其 NAT 小鸡）的 `/tmp` 是内存盘（tmpfs），解压 68MB 的 sing-box 会占用容器内存配额导致卡顿断连——脚本会自动检测并改用 xray（体积小一半），无需手动干预。
5. **关闭密码登录前**：确保新的 SSH 私钥已保存，再输入 `yes`，避免锁死。
6. **服务端自检 vs NAT 映射**：脚本装完会本机自检（验证服务端 Reality + 出站）。**自检仅在 relay（Reality）模式执行，landing（SS）模式自动跳过**。自检通过但你外部连不上 → 问题在 NAT 映射（外部端口是否映射到这台机器），查服务商面板。
7. **远程拉取请用带超时的写法**（见上方代码块）：无超时的 `wget -qO- <URL> | sh` 在双栈机器（IPv6 黑洞）上会静默卡死十几分钟、屏幕空白。推荐命令改为 curl 优先并带 `--connect-timeout 10 -m 60`（失败立即报错），wget / busybox 兜底时也加了 `-T 15`。
8. **遇到"没有输出 / 屏幕空白 / 连接失败 / 验证失败"先排查，别急着重跑**：重连后按下面顺序逐项检查（这也是本脚本断线免疫设计的一部分）：
   1. `tail -f /root/install_reality.log` —— **脚本断开时会转入后台续跑，输出全写进这个日志**。"没有输出"往往是正常现象，进度都在这。
   2. `systemctl status sing-box`（或 `xray`）—— 看代理服务有没有起来。
   3. `cat /etc/sing-box/node_output.txt`（或执行 `shownode`）—— 看节点链接是否已生成。
   4. `ls -l /root/.ssh/id_ed25519` —— 确认私钥文件还在不在（默认保留，但若曾被手动删过则需注意）。
   5. 如果 SSH 报**"验证失败"**：基本可以确定是"私钥没存到本地 + 密码登录已被关"的锁死组合。请先联系商家用**面板重置登录方式/控制台重置**救回，千万别再次强行操作，这是唯一可靠救法。救回后跑修复版脚本，私钥默认保留就不会再丢。

---

## 输出文件与路径

| 路径 | 内容 |
|------|------|
| `/etc/sing-box/config.json` 或 `/usr/local/etc/xray/config.json` | 服务端配置（按内核）|
| `/etc/sing-box/node_output.txt` | 节点连接信息（vless/ss 链接）|
| `/var/log/sing-box.log` | 运行日志（仅 sing-box 分支；xray 分支不写日志文件）|
| `/etc/logrotate.d/sing-box` | 日志轮转规则（仅 sing-box 分支）|
| `/etc/systemd/system/sing-box.service`、`/etc/init.d/sing-box` 或对应 xray 版 | 服务定义（按系统/内核）|
| `/etc/ssh/sshd_config.d/00-disable-password.conf` | 关闭密码登录 drop-in（执行后）|
| `/root/.ssh/id_ed25519`（及 `.pub`）| SSH 私钥（断连转后台续跑时保留，权限600）与公钥 |
| `/usr/local/bin/sshkey` | `sshkey` 命令本体（仅查看/确认删除 SSH 私钥）|
