# install_reality.sh — VLESS+Reality / Shadowsocks 节点一键安装

单文件自举，一条命令完成节点部署。兼容 **Alpine / Debian / Ubuntu / Fedora / CentOS / openSUSE**，内核（xray / sing-box）自动选择。

| MODE | 角色 | 协议 |
|------|------|------|
| `relay`（默认）| 中转节点 | VLESS + Reality |
| `landing` | 落地节点 | Shadowsocks（aes-128-gcm）|

---

## 目录

- [快速安装](#快速安装)
- [常用环境变量](#常用环境变量)
- [端口逻辑](#端口逻辑)
- [内核与断线免疫](#内核与断线免疫)
- [重跑合并：保留 argo](#重跑合并保留-argo)
- [SSH 私钥](#ssh-私钥)
- [关闭密码登录（已移出）](#关闭密码登录已移出)
- [故障排查](#故障排查)
- [输出文件与路径](#输出文件与路径)

---

## 快速安装

先把脚本下载到本地、带超时，再执行（避免双栈机器 IPv6 黑洞时静默卡住）。把下面的 `a` `b` `y` `z` 换成你自己的值：

**中转节点（VLESS Reality，默认）：**

```bash
if command -v curl >/dev/null 2>&1; then curl -fL --connect-timeout 10 -m 60 -o /tmp/install_reality.sh https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh; elif command -v wget >/dev/null 2>&1; then wget -q -T 15 -O /tmp/install_reality.sh https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh; elif command -v busybox >/dev/null 2>&1; then busybox wget -q -T 15 -O /tmp/install_reality.sh https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh; else echo '需要 curl/wget/busybox 之一' >&2; exit 1; fi && ACTUAL_LISTEN_PORT=a LISTEN_PORT=b SERVER_IP=y NODE_NAME=z sh /tmp/install_reality.sh
```

**落地节点（Shadowsocks）：** 同一行命令前加 `MODE=landing `（含空格）即可：

```bash
if command -v curl >/dev/null 2>&1; then curl -fL --connect-timeout 10 -m 60 -o /tmp/install_reality.sh https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh; elif command -v wget >/dev/null 2>&1; then wget -q -T 15 -O /tmp/install_reality.sh https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh; elif command -v busybox >/dev/null 2>&1; then busybox wget -q -T 15 -O /tmp/install_reality.sh https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh; else echo '需要 curl/wget/busybox 之一' >&2; exit 1; fi && MODE=landing ACTUAL_LISTEN_PORT=a LISTEN_PORT=b SERVER_IP=y NODE_NAME=z sh /tmp/install_reality.sh
```

> `MODE` 合法值只有 `relay` / `landing`，填其它值会回退到 `relay`。

---

## 常用环境变量

必填三个：`ACTUAL_LISTEN_PORT`、`LISTEN_PORT`、`SERVER_IP`（缺一即退出，目的是让你明说、不猜）。

| 变量 | 含义 | 示例 |
|------|------|------|
| `ACTUAL_LISTEN_PORT` | **实际监听端口**，写进 config 的 `listen_port`，填商家放行给你的端口 | `2053` |
| `LISTEN_PORT` | **输出/映射端口**，写进链接与防火墙；NAT 填外部映射端口，非 NAT 填与实际相同 | `62879` 或 `2053` |
| `SERVER_IP` | 服务器公网 IP | `45.207.35.102` |
| `NODE_NAME` | 节点名（链接/YAML 里显示，可带 emoji，中间不能有空格）| `lzycat🇯🇵` |
| `REALITY_DEST` | Reality 伪装握手目标（默认 `addons.mozilla.org:443`）| `www.microsoft.com:443` |
| `REALITY_SERVER_NAME` | 客户端 SNI（默认 `addons.mozilla.org`）| `www.microsoft.com` |
| `SS_METHOD` | SS 加密方式（默认 `aes-128-gcm`）| `aes-256-gcm` |
| `SS_PASSWORD` | SS 密码，不设则随机生成 | `mysecret` |
| `SSH_KEY_REGENERATE` | `1` = 强制重新生成 SSH 密钥（当只剩公钥、私钥已删无法恢复时用）| `1` |
| `SSH_KEY_DELETE` | `1` = 强制"打印一次即删"（默认不删，见下）| `1` |
| `SCRIPT_URL` | 管道模式下载脚本地址覆盖 | `https://…/install.sh` |
| `INSTALL_LOG` | 断连续跑日志路径（默认 `/root/install_reality.log`）| `/root/my.log` |
| `LISTEN_ADDR` | 监听地址，默认 `0.0.0.0`；双栈机器可改 `::` | `0.0.0.0` |

---

## 端口逻辑

两个端口独立设置、都必填，互不绑定：

| 场景 | ACTUAL_LISTEN_PORT | LISTEN_PORT |
|------|--------------------|-------------|
| 非 NAT（常见）| 商家放行端口，如 `2053` | 填一样 `2053` |
| NAT 机器 | 内部实际监听，如 `2053` | 映射后的外部端口，如 `62879` |
| 端口不限商家 | 任意，如 `443` | 填一样 `443` |

> `ACTUAL_LISTEN_PORT` 必须填商家**实际放行给我监听**的端口；`LISTEN_PORT` 是展示/防火墙上用的输出端口。

---

## 内核与断线免疫

- **内核自适应**：自动检测 `/tmp` 是否为内存盘（tmpfs）——是则用 **xray**（体积约 sing-box 一半，小内存容器能装），否则用 **sing-box**。两种内核产出的客户端链接格式一致，使用端无感。
- **断线免疫**：平时前台正常执行；SSH 断开的瞬间捕获 SIGHUP 自动转入后台续跑（幂等），日志在 `/root/install_reality.log`（`INSTALL_LOG` 可覆盖），重连后 `tail -f` 查看进度。
- **稳健下载**：支持断点续传 + 最多 5 次自动重试，落盘做 md5/大小校验 + 重试 3 次，应对 NAT 慢速/网关重置。
- **架构自适应**：x86_64 / arm64 / 386 / armv7 / riscv64 / s390x 自动映射。
- **服务端自检**：装完本机直连验证 Reality 握手 + 出站（Google 204）。仅 relay 模式执行，SS 模式跳过。自检通过但你外网连不上 → 问题在 NAT 映射，查商家面板。

---

## 重跑合并：保留 argo

脚本可安全重复运行。每次会把 `inbounds` **只保留 argo 类节点**（vless+ws 或 tag 为 `argo-in`），其余全部清除，再写入本次所选分支节点。最终恒为 `[ argo节点(如有), 本次所选节点 ]`。

- 无 argo 不报错，结果就是单个干净节点。
- 自动备份到 `/etc/sing-box/config.json.bak.<时间戳>`。
- 依赖 `jq`（自动按包管理器安装）。
- 重跑 landing 时 SS 密码会重新随机（除非 `SS_PASSWORD` 固定）。

---

## SSH 私钥

脚本生成 ed25519 私钥后，**默认保留在服务器** `/root/.ssh/id_ed25519`（权限 600），前台和断连续跑**都不自动删除**——即使你没看清屏幕/中途断线，私钥也不会丢失。这是**防锁死**的关键。

- 重连后执行 `sshkey` 查看私钥，**确认已在本地保存后才输入 `yes` 删除**；`sshkey --delete` 可直接删。
- `sshkey` 只管私钥查看/删除，**不管密码登录**。
- 若提示"已有公钥但私钥已不存在（无法恢复）"：原公钥无法找回对应私钥，用 `SSH_KEY_REGENERATE=1` 重新生成一份新密钥对并保存。
- 私钥相关输出会写入安装日志，保存私钥后建议清理该日志。

---

## 关闭密码登录（已移出）

> 本脚本**已不再负责关闭密码登录**，改放到独立的 bbr（网络加速）脚本中处理，二者互不干扰。本脚本只装节点 + 生成/保留 SSH 私钥。
>
> bbr 脚本里关密码前：先确认服务器有可用的私钥文件、你本地已保存好对应私钥，再关——否则关掉密码后只能靠密钥登录，私钥一丢就锁死。

---

## 故障排查

遇到"没有输出 / 屏幕空白 / 连接失败 / 验证失败"先排查，**别急着重跑**：

1. `tail -f /root/install_reality.log` —— 断开时脚本转后台续跑，输出都在这里。"没有输出"往往是正常现象。
2. `systemctl status sing-box`（或 `xray`）—— 看代理服务有没有起来。
3. `cat /etc/sing-box/node_output.txt`（或 `shownode`）—— 看节点链接是否已生成。
4. `ls -l /root/.ssh/id_ed25519` —— 确认私钥文件还在不在。
5. 若 SSH 报**"验证失败"**：基本是"私钥没存到本地 + 密码登录已被关"的锁死组合。用商家**面板重置登录方式**救回，别强行操作；救回后跑修复版脚本（私钥默认保留，不会再丢）。

---

## 输出文件与路径

| 路径 | 内容 |
|------|------|
| `/etc/sing-box/config.json` 或 `/usr/local/etc/xray/config.json` | 服务端配置（按内核）|
| `/etc/sing-box/node_output.txt` | 节点连接信息（vless/ss 链接）|
| `/var/log/sing-box.log` | 运行日志（仅 sing-box 分支）|
| `/etc/logrotate.d/sing-box` | 日志轮转规则（仅 sing-box 分支）|
| `/etc/systemd/system/{sing-box,xray}.service` 或 `/etc/init.d/…` | 服务定义（按系统/内核）|
| `/root/.ssh/id_ed25519`（及 `.pub`）| SSH 私钥（默认保留，权限 600）与公钥 |
| `/usr/local/bin/sshkey` | `sshkey` 命令本体（仅查看/确认删除私钥）|