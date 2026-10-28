# install_reality.sh — REALITY / Shadowsocks / HY2 节点一键安装

单文件自举，统一使用 **sing-box** 内核。支持 Alpine（OpenRC）以及 Debian / Ubuntu / Fedora / CentOS / openSUSE 等使用 systemd 的系统。可从 `sh` 启动，脚本会补齐 bash / curl 并转入 bash 执行。

| MODE | 安装内容 | 服务端传输 |
| --- | --- | --- |
| `reality`（默认） | VLESS + REALITY + Vision | TCP |
| `ss` | Shadowsocks，默认 `aes-128-gcm` | TCP / UDP |
| `hy2` | Hysteria 2，默认 Gecko 混淆 | UDP |
| `both` | 同时安装 REALITY 和 HY2 | TCP + UDP |

模式名已由 `relay` 改为 `reality`、由 `landing` 改为 `ss`。旧命令需要相应修改；未知模式直接报错，避免误装。

> 每次运行会替换 sing-box 主配置中除 Argo 以外的所有入站节点，再写入所选模式。重跑后使用新输出的客户端配置。脚本不会自动设置商家 NAT 面板的端口映射。

## 目录

- [快速安装](#快速安装)
- [常用环境变量](#常用环境变量)
- [端口逻辑与 NAT 映射](#端口逻辑与-nat-映射)
- [HY2 混淆与证书](#hy2-混淆与证书)
- [内核与断连续跑](#内核与断连续跑)
- [重跑覆盖：只保留 Argo](#重跑覆盖只保留-argo)
- [客户端配置](#客户端配置)
- [SSH 密钥与登录保护](#ssh-密钥与登录保护)
- [故障排查](#故障排查)
- [输出文件与路径](#输出文件与路径)

## 快速安装

以下以 root 执行。先下载到本地，下载失败时不要执行残留文件：

```sh
if command -v curl >/dev/null 2>&1; then
  curl -fL --connect-timeout 10 -m 60 \
    -o /tmp/install_reality.sh \
    https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh
elif command -v wget >/dev/null 2>&1; then
  wget -T 20 -O /tmp/install_reality.sh \
    https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh
elif command -v busybox >/dev/null 2>&1; then
  busybox wget -T 20 -O /tmp/install_reality.sh \
    https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh
else
  printf '%s\n' '需要 curl / wget / busybox 之一' >&2
  exit 1
fi
```

确认下载成功，再选下面一种模式执行。示例 IP `203.0.113.10` 必须替换成自己的公网 IP。

### REALITY

```sh
MODE=reality \
SERVER_IP=203.0.113.10 \
ACTUAL_LISTEN_PORT=20116 \
LISTEN_PORT=20116 \
NODE_NAME='我的REALITY' \
sh /tmp/install_reality.sh
```

NAT 机器若公网 TCP `30116` 映射到内网 TCP `20116`，将 `LISTEN_PORT` 改成 `30116`，`ACTUAL_LISTEN_PORT` 仍填 `20116`。

### Shadowsocks

```sh
MODE=ss \
SERVER_IP=203.0.113.10 \
ACTUAL_LISTEN_PORT=20116 \
LISTEN_PORT=20116 \
NODE_NAME='我的SS' \
sh /tmp/install_reality.sh
```

需要 SS 的 UDP 功能时，还要在商家面板放行或映射对应 UDP 端口。

### HY2：固定公网端口

```sh
MODE=hy2 \
SERVER_IP=203.0.113.10 \
HY2_LISTEN_PORT=20116 \
HY2_SERVER_PORTS=20116 \
NODE_NAME='我的HY2' \
sh /tmp/install_reality.sh
```

默认启用 Gecko；客户端和服务端内核都必须支持它。默认自动生成自签证书，手机配置内嵌公开证书并校验，无需 Cloudflare API。

### HY2：六个公网端口跳跃（适用于已配置相应 NAT 映射）

```sh
MODE=hy2 \
SERVER_IP=203.0.113.10 \
HY2_LISTEN_PORT=20116 \
HY2_SERVER_PORTS=20116-20121 \
HY2_HOP_INTERVAL=30s \
NODE_NAME='我的HY2' \
sh /tmp/install_reality.sh
```

这不会自动让六个端口可达。必须先按下文将 **六个公网 UDP 端口全部转发到一个内网 UDP `20116`**。独立公网 IP 机器也需要额外的端口重定向规则才能使用这种多端口配置。

### 同时安装 REALITY 和 HY2

```sh
MODE=both \
SERVER_IP=203.0.113.10 \
ACTUAL_LISTEN_PORT=20116 \
LISTEN_PORT=20116 \
HY2_LISTEN_PORT=20116 \
HY2_SERVER_PORTS=20116-20121 \
NODE_NAME='我的节点' \
sh /tmp/install_reality.sh
```

REALITY 使用 TCP `20116`，HY2 使用 UDP `20116`，同一端口号不冲突。NAT 面板中 TCP 和 UDP 规则分别设置。

## 常用环境变量

所有端口必须是 `1–65535` 的数字。公网多端口只填写商家允许使用的范围。

| 变量 | 含义 / 默认值 |
| --- | --- |
| `MODE` | `reality`（默认）/ `ss` / `hy2` / `both` |
| `SERVER_IP` | 所有模式必填；客户端连接的公网 IP 或域名 |
| `ACTUAL_LISTEN_PORT` | `reality` / `ss` / `both` 必填；REALITY 或 SS 在本机监听的端口 |
| `LISTEN_PORT` | `reality` / `ss` / `both` 必填；客户端使用的公网 REALITY 或 SS 端口 |
| `HY2_LISTEN_PORT` | HY2 在本机监听的 UDP 端口；未填时可使用 `ACTUAL_LISTEN_PORT` |
| `HY2_SERVER_PORTS` | 客户端使用的公网 UDP 端口；未填时可使用 `LISTEN_PORT`。支持单个端口、逗号分隔、范围，例如 `20116`、`20116-20121`、`20116:20121,30116` |
| `HY2_HOP_INTERVAL` | 多端口跳跃间隔，默认 `30s`；单端口不启用跳跃 |
| `HY2_SNI` | 自签证书名称及客户端 TLS server_name，默认 `hy2.local`；不要求有真实 DNS 解析 |
| `HY2_OBFS` | `gecko`（默认）/ `salamander` / `none`；两端必须使用一致的混淆方式 |
| `HY2_PASSWORD` | HY2 认证密码；未填时随机生成 |
| `HY2_OBFS_PASSWORD` | HY2 混淆密码；未填时随机生成，与认证密码是两项不同的设置 |
| `NODE_NAME` | 节点名称，包含空格时用引号包住 |
| `REALITY_DEST` | REALITY 握手目标，例如 `www.libreoffice.org:443`；未填时自动探测候选列表 |
| `REALITY_SERVER_NAME` | REALITY 的客户端 SNI；未填时从握手目标推导 |
| `REALITY_DEST_CANDIDATES` | REALITY 自动探测候选列表，空格分隔 |
| `LISTEN_ADDR` | 服务端监听地址，默认 `0.0.0.0`；双栈按系统实际情况选择 |
| `SS_METHOD` | SS 加密方式，默认 `aes-128-gcm` |
| `SS_PASSWORD` | SS 密码，未填时随机生成 |
| `SCRIPT_URL` | 管道自举时重新下载本脚本的地址 |
| `INSTALL_LOG` | SSH 断开后重跑的日志路径，默认 `/root/install_reality.log` |
| `SSH_KEY_REGENERATE` | 仅显式设置 `1` 时重建脚本使用的 SSH 密钥对；旧密钥文件先备份，已有授权记录保留 |
| `SSH_KEY_DELETE` | 仅显式设置 `1` 时，显示后删除服务器上的脚本私钥副本；默认不删除 |

## 端口逻辑与 NAT 映射

### REALITY / SS

| 场景 | 本机监听 | 公网连接端口 |
| --- | --- | --- |
| 独立公网 IP | `ACTUAL_LISTEN_PORT=20116` | `LISTEN_PORT=20116` |
| NAT 映射 | `ACTUAL_LISTEN_PORT=20116` | `LISTEN_PORT=30116`，商家映射 `30116 → 20116` |

REALITY 要 TCP 映射；SS 根据实际功能需要 TCP 和 UDP。

### HY2

固定端口例子：

```text
公网 UDP 30116 → 内网 UDP 20116
HY2_SERVER_PORTS=30116
HY2_LISTEN_PORT=20116
```

六端口跳跃例子，面板批量添加格式为 `外部:内部`：

```text
20116:20116
20117:20116
20118:20116
20119:20116
20120:20116
20121:20116
```

以上全部选择 **UDP**。服务端只监听一个 UDP 端口，多个公网入口要进入同一个 HY2 实例，以便保持 QUIC 连接状态。

注意：

- **只写 `HY2_SERVER_PORTS` 不会创建映射或重定向。** 脚本不拥有商家宿主机 NAT 权限。
- 若面板不允许多对一映射，需要商家支持，或有权限时另行设置适当的转发；不能改成六个互不关联的 HY2 监听器就认为连接迁移正常。
- 独立公网 IP 机器默认先用单端口。多端口跳跃需要将额外公网 UDP 端口重定向到同一服务监听端口，并处理防火墙及持久化；本脚本不会擅自修改 NAT 表。
- 本机防火墙放行实际服务监听端口；公网端口还需在云安全组或商家面板放行。
- 不要删除现有 SSH 端口映射。

## HY2 混淆与证书

### Gecko 与内核

HY2 默认使用 Gecko，需要支持该功能的 sing-box（1.14 系列及兼容后续版本）以及匹配的客户端。脚本会检查实际配置能力，不能只因为本机存在一个可执行的 sing-box 就认定 Gecko 可用。

若已安装内核缺少所需功能，先按提示升级内核，再重跑；不会悄悄降级成另一种混淆。需要兼容不支持 Gecko 的客户端时，可显式选择 `HY2_OBFS=salamander` 或 `HY2_OBFS=none`，并使用对应新输出配置。

Gecko 和端口跳跃不保证任何网络下都能连接，也不保证比固定端口更快。

### 为什么不需要 Cloudflare API

脚本生成指定名称的自签证书，将**公开证书**内嵌到手机配置，服务器私钥留在服务器。客户端按证书信任关系及名称进行校验，未启用 `insecure`。

Cloudflare DNS API 一般用于向公开证书机构申请和续期证书所需的 DNS 验证，本方案不使用这条流程。

默认名称 `hy2.local` 只是证书名称。客户端直接连接 `SERVER_IP`，不需要解析 `hy2.local`。如果 `SERVER_IP` 填 Cloudflare 上的域名，该记录必须能直接到达服务器；普通橙云代理不能转发此 HY2 UDP 服务，应使用“仅 DNS”。

自签证书不是永久有效。生成的证书默认约三年，到期前需要更换，并同步更新客户端中的证书。修改 SNI 后也要确保客户端与服务器证书对应。

HY2 默认不填激进带宽值，使用 `ignore_client_bandwidth=true` 引导客户端使用 BBR。

## 内核与断连续跑

- **统一 sing-box**：复用已有可运行内核；需要 HY2 时另外检查 QUIC / 混淆配置能力。新装下载官方发行包，按 CPU 架构选择。
- **下载与自举**：支持 curl / wget / busybox 起步；安装包下载带连接超时和重试，临时解压放在 `/var/tmp`。
- **REALITY 目标预检**：仅 `reality` / `both` 执行，探测可达目标；HY2 / SS 不需要 REALITY 握手目标。
- **SSH 断开**：捕获 SIGHUP 后尝试后台重新运行脚本，日志位于 `INSTALL_LOG`。这是从头重跑，不是精确断点恢复，可能重新生成节点凭据；不是所有断网/进程被杀场景都能捕获。
- **服务管理**：使用 systemd 或 OpenRC 注册开机服务。
- **自检**：经本机临时客户端完成所选节点的代理请求；自检通过仅证明服务器内部服务可用，不代表公网 UDP / TCP 映射已通过。
- **其他独立服务**：脚本管理 `/etc/sing-box/config.json` 和 `sing-box` 服务。不会自动停止其他程序或另一个配置目录启动的代理服务；若端口冲突会失败，需要先确认占用来源。

## 重跑覆盖：只保留 Argo

四种模式都按下列规则更新 `inbounds`：

| 模式 | 最终入站列表 |
| --- | --- |
| `reality` | 原 Argo + 新 REALITY |
| `ss` | 原 Argo + 新 SS |
| `hy2` | 原 Argo + 新 HY2 |
| `both` | 原 Argo + 新 REALITY + 新 HY2 |

Argo 沿用旧脚本识别规则：`tag` 为 `argo-in`，或 `type=vless` 且 `transport.type=ws`。注意，后者也会保留满足条件但实际并非 Argo 的 VLESS WebSocket 入站，脚本无法只凭传输配置确认是否有 Cloudflare Tunnel。

- 原 REALITY / HY2 / SS 以及其他非 Argo 入站全部从主配置删除，不只是同名节点。
- 两节点模式一次生成并合并，避免第二次写入删掉第一个。
- 其他顶层字段保留；配置本身不合法时直接报错，避免把损坏文件误当成“空配置”覆盖。
- 原配置先备份，新配置通过 `sing-box check` 后才替换；服务启动或所选节点自检失败时，恢复原配置并尝试恢复服务。
- 默认生成新的节点认证信息；固定密码可用环境变量指定。每次成功安装后，使用本次输出的配置。
- 这里的“删除节点”只针对 sing-box 配置的入站项，不会清空 `/root/.ssh`、删除 `authorized_keys` 或关闭 SSH 密码登录。

## 客户端配置

安装成功后执行 `shownode`，或者查看：

```sh
cat /etc/sing-box/node_output.txt
```

完整手机配置位于 `/etc/sing-box/client.json`，包括 TUN、DNS、路由和所选节点。`both` 模式可选择 REALITY 或 HY2；另外输出各自独立的完整手机配置，方便单独测试。

如果已有一份自己的分流配置，用 `/etc/sing-box/client-outbounds.json` 中的节点对象合并到现有 `outbounds`，再将自己的选择器或路由指向对应标签，不要用完整手机配置片段直接覆盖分流规则。

Gecko、证书信任和端口跳跃以 sing-box JSON 为准，不把普通 `hysteria2://` 链接当作能完整表达且所有客户端兼容的配置。

客户端配置内含认证密码，应按私人凭据保存。内嵌公开证书不是服务器私钥。

## SSH 密钥与登录保护

**切换 MODE 或替换节点不会删除 SSH 登录验证文件。** 脚本不会修改密码登录开关，也不会重启 SSH 服务。

首次需要生成脚本管理的密钥时，使用 Ed25519：

- `/root/.ssh/id_ed25519`：私钥，默认保留，权限 `600`。
- `/root/.ssh/id_ed25519.pub`：公钥。
- `/root/.ssh/authorized_keys`：追加公钥，保留已有记录。

默认重跑保留已有密钥。若只剩私钥，尝试推导对应公钥；若只剩公钥，不会为了安装节点擅自删除它并重建密钥。

显式 `SSH_KEY_REGENERATE=1` 会先备份脚本管理的旧密钥文件，再生成一对新密钥，并保留已有 `authorized_keys` 中的授权。它不会像旧逻辑那样删除所有 Ed25519 授权记录。

`sshkey` 默认只查看私钥并保留文件，不再要求输入 `yes`。确认已经在本地保存后，显式运行 `sshkey --delete` 才删除服务器副本；`SSH_KEY_DELETE=1` 也是主动要求删除的操作。删除服务器私钥副本不等于撤销已授权公钥；请先在本地保存好私钥。

私钥或节点凭据可能出现在安装终端及断连续跑日志中，保存后妥善处理日志。

关闭密码登录仍不在本脚本范围内。无论用哪个其他脚本关闭，都应先实际验证本地密钥能重新登录。

## 故障排查

1. **看服务状态**：systemd 使用 `systemctl status sing-box`；Alpine 使用 `rc-service sing-box status`。
2. **看配置校验**：`sing-box check -c /etc/sing-box/config.json`。
3. **看日志**：`tail -n 80 /var/log/sing-box.log`；SSH 中断重跑时查看 `/root/install_reality.log`。
4. **HY2 提示 Gecko 不支持**：核对双方实际内核能力；App 已更新不必然等于其内核支持 Gecko。
5. **本机自检通过，手机超时**：检查商家公网映射、协议选择、云安全组，以及当前网络是否允许 UDP。TCP 映射不能代替 HY2 的 UDP 映射。
6. **单端口可用，跳跃后不通**：检查六个公网 UDP 端口是否全部进入同一个服务监听端口，不能遗漏或逐一映射到六个不同内网端口。
7. **端口占用**：用 `ss -lntup` 查看占用程序，不要直接杀掉不明进程。
8. **切换模式后旧手机配置失效**：使用本次安装输出的新配置，这是覆盖安装的预期行为。
9. **SSH 验证失败**：先确认用户名、端口和本地密钥；不要把节点配置覆盖与 SSH 授权删除混为一谈。需要救援时使用商家控制台。

## 输出文件与路径

| 路径 | 内容 |
| --- | --- |
| `/etc/sing-box/config.json` | 当前服务端配置 |
| `/etc/sing-box/config.json.bak.*` | 覆盖前的服务端配置备份 |
| `/etc/sing-box/node_output.txt` | 本次节点连接信息及客户端使用提示 |
| `/etc/sing-box/client.json` | 本次模式完整手机配置；双模式包含选择器 |
| `/etc/sing-box/client-outbounds.json` | 本次节点出站对象数组，适合并入已有客户端配置 |
| `/etc/sing-box/client-reality.json` | 启用 REALITY 时输出的独立完整手机配置 |
| `/etc/sing-box/client-hy2.json` | 启用 HY2 时输出的独立完整手机配置 |
| `/etc/sing-box/client-ss.json` | 启用 SS 时输出的独立完整手机配置 |
| `/etc/sing-box/hy2-tls/` | HY2 自签证书与私钥的独立目录，按证书名称组织；旧证书文件保留，便于配置回滚 |
| `/var/log/sing-box.log` | sing-box 运行日志 |
| `/etc/logrotate.d/sing-box` | 日志轮转配置 |
| `/etc/systemd/system/sing-box.service` 或 `/etc/init.d/sing-box` | 服务定义 |
| `/root/.ssh/id_ed25519`、`.pub` | 脚本管理的 SSH 密钥对 |
| `/root/.ssh/authorized_keys` | SSH 公钥授权记录 |
| `/usr/local/bin/sshkey` | 私钥查看 / 确认删除工具 |

具体证书目录及本次输出以脚本终端提示为准。
