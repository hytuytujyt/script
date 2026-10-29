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
- [HY2 可选聚合发送限速](#hy2-可选聚合发送限速)
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

### HY2：六个公网端口跳跃（商家 NAT，默认 external）

```sh
MODE=hy2 \
SERVER_IP=203.0.113.10 \
HY2_LISTEN_PORT=20116 \
HY2_SERVER_PORTS=20116-20121 \
HY2_HOP_INTERVAL=30s \
NODE_NAME='我的HY2' \
sh /tmp/install_reality.sh
```

上述默认 `HY2_PORT_HOPPING_MODE=external`：不会创建本机 NAT。必须在商家面板将 **六个公网 UDP 端口全部转发到一个内网 UDP `20116`**。

### HY2：普通公网 VPS 自动跳跃（local）

```sh
MODE=hy2 \
SERVER_IP=203.0.113.10 \
HY2_LISTEN_PORT=20116 \
HY2_SERVER_PORTS=30000-40000,45000:45010 \
HY2_PORT_HOPPING_MODE=local \
HY2_HOPPING_INTERFACE=eth0 \
ENABLE_VPS_SHAPING=1 \
VPS_UPLOAD_MBIT=100 \
sh /tmp/install_reality.sh
```

替换公网 IP 和实际公网网卡名。云厂商 1:1 NAT 常使用私网地址，或默认路由无法证明是公网网卡时，请显式设置 `HY2_HOPPING_INTERFACE`（或 `VPS_SHAPING_INTERFACE`）；显式网卡不受公网地址自动检测限制。`ENABLE_VPS_SHAPING` 可省略，local 跳跃不要求开启限速。脚本补装 nftables，并用独立 `inet hy2_hopping` 表将指定网卡、**目标确属本机**的指定 UDP 范围重定向到单一 `HY2_LISTEN_PORT`；不捕获普通转发目的流量、不接管全局防火墙。监听端口在范围内或范围外都合法。范围排序合并重叠/相邻项，最多 64 个不连续区间，不按端口生成数万条命令。

规则同时适用于 IPv4/IPv6；HY2 服务是否双栈仍由监听地址和系统决定，需要时显式 `LISTEN_ADDR=::` 并核实系统 IPv4-mapped socket 行为，本脚本不更改 sysctl。inet NAT 需要 Linux ≥5.2；通过 `nft -c` 和真实应用检查能力/权限，不升级内核、不加载模块、不授予 capability。**请在云安全组放行整个公网 UDP 范围**，脚本不自动操作云安全组。主机 INPUT 防火墙看到重定向后的单监听端口，脚本仍只按既有逻辑放行该端口；自定义 raw/prerouting、防火墙或 conntrack 策略需人工评估。

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
| `HY2_PORT_HOPPING_MODE` | `external`（默认，保留商家 NAT 行为，不创建本机规则）/ `local`（自动本机 nft inet redirect） |
| `HY2_HOPPING_INTERFACE` | local 入站公网网卡；省略使用显式 `VPS_SHAPING_INTERFACE`，否则仅在双栈默认路由唯一明确时选择，不猜多网卡/策略路由；重跑未显式指定会重新检测 |
| `HY2_HOP_INTERVAL` | 多端口跳跃间隔，默认 `30s`；单端口不启用跳跃 |
| `HY2_SNI` | 自签证书名称及客户端 TLS server_name，默认 `hy2.local`；不要求有真实 DNS 解析 |
| `HY2_OBFS` | `gecko`（默认）/ `salamander` / `none`；两端必须使用一致的混淆方式 |
| `HY2_PASSWORD` | HY2 认证密码；未填时随机生成 |
| `HY2_OBFS_PASSWORD` | HY2 混淆密码；未填时随机生成，与认证密码是两项不同的设置 |
| `ENABLE_VPS_SHAPING` | **仅 HY2** 聚合发送限速；首次省略不开启且不调用 tc，`1` 开启，`0` 显式关闭；HY2 重装省略时保留保存设置并跟随新本机端口 |
| `VPS_UPLOAD_MBIT` | **仅 HY2** 服务器发往客户端的 UDP 总上限，正整数 `1..10000` Mbps；首次开启默认 `100`，重装省略沿用保存值，非 MB/s |
| `VPS_SHAPING_INTERFACE` | **仅 HY2** 出口网卡；首次自动从 IPv4/IPv6 全路由表默认路由检测唯一网卡，歧义直接失败；重装省略沿用保存网卡 |
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

- 默认 external：**只写 `HY2_SERVER_PORTS` 不会创建映射或重定向。** 脚本不拥有商家宿主机 NAT 权限。
- 若面板不允许多对一映射，需要商家支持，或有权限时另行设置适当的转发；不能改成六个互不关联的 HY2 监听器就认为连接迁移正常。
- 普通公网 VPS 可显式选择 local，安装器管理独立自有表、重跑更新及启动恢复；external 不新建规则，local → external 只移除经完整指纹验证的自有表。不会 flush 全规则，不删除陌生表。
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

HY2 保持 `ignore_client_bandwidth: true`，不设置服务端 `up_mbps` / `down_mbps`，保留 HY2 的 BBR 行为；不修改系统 TCP BBR 或其他协议的拥塞配置。

## HY2 可选聚合发送限速

### 两步安装示例

第一步使用上面“快速安装”的下载命令，将脚本保存为 `/tmp/install_reality.sh`。第二步启用 **仅 HY2** 的 100 Mbps 上限（可调），而不是给 VPS 全机限速：

```sh
MODE=hy2 \
SERVER_IP=203.0.113.10 \
HY2_LISTEN_PORT=20116 \
HY2_SERVER_PORTS=20116 \
ENABLE_VPS_SHAPING=1 \
VPS_UPLOAD_MBIT=100 \
sh /tmp/install_reality.sh
```

`MODE=both` 也支持；REALITY 不受此速率上限影响。启用、继承或管理已有 HY2 限速时，安装器会检查并通过已有包管理器**自动补齐缺失的普通用户态工具**，不再要求先手工安装 tc/flock。独立的 `hy2-limit` 命令不会偷偷装包；jq / curl / openssl 仍走原有安装逻辑。

| 包管理器 | `ip` / `tc` | `flock` |
| --- | --- | --- |
| apt-get / zypper / pacman | `iproute2` | `util-linux` |
| dnf / yum | `iproute` / `iproute-tc` | `util-linux` |
| apk（Alpine） | `iproute2` / `iproute2-tc` | `flock`（util-linux 的独立子包，不假定 util-linux-misc 提供） |

还检查 `stat`、`mktemp`、`cmp`、`dirname` 以及 helper/安装集成实际使用的基础文件工具；缺失时按需安装 `coreutils` / `diffutils`，已有 BusyBox 工具能力足够则不强制替换。读取旧状态之前先保障 `stat -c` 可用，避免继承设置时先因缺工具失败。NAT 可读检查若既无 `nft` 又无完整的 `iptables-save` + `ip6tables-save`，会补装 `nftables`；**脚本不为此 enable/start/reload 防火墙服务、不加载默认规则、不清空全局规则**；仅显式 local 模式会管理独立自有 NAT 表。第三方发行版包的安装 hook 属于包管理器行为，不能保证其绝无系统副作用；有严格变更策略的系统应先人工审查/预装包。

安装成功不等于能力可用：安装后重新检查命令，并验证 stat/cmp/mktemp/flock 的所需操作以及 tc/ip/nft 的只读 JSON 输出。现有工具过旧、JSON 不可读、软件仓库/安装失败、没有受支持的包管理器、缺少 root/CAP_NET_ADMIN 等权限或 systemd/OpenRC、Linux 内核不支持 prio/TBF/flower 时，均明确失败，**不静默跳过**。不会自动安装 Linux kernel、modprobe、授予网络能力或修改系统权限来绕过限制。实际内核/队列能力仍由应用及规则复核判断，不以用户态探测代替；精确识别的自有 local NAT 表允许通过，**商家外部 NAT 继续支持**；其他本机 NAT 见下面的保守限制。

首次不传开关不启用、不创建限速文件、不调用 tc。已经保存的 HY2 设置在重装时沿用，规则跟随新的 `HY2_LISTEN_PORT`，不会因为省略开关而让新端口绕开限速。`ENABLE_VPS_SHAPING=0` 显式关闭；如果先前从未启用，保持无操作。切换 `reality` / `ss` 时，若旧 HY2 限速仍开启，安装器拒绝切换，限速可先运行 `hy2-limit off`；如 local 跳跃仍启用则先 `hy2-limit disable-all`；不自动删除未知规则，也不让旧 HY2 源端口规则误限后续 SS。已关闭的管理状态及 helper 可保留；切出 HY2 时，精确内容与所有权检查通过后移除专用 systemd drop-in，OpenRC 新单位不再带 HY2 依赖。`set` / 开机恢复还会验证保存路径的当前 sing-box 配置确有对应 `hy2-in` UDP 端口（配置需 root 所有、600，拒绝而非自动改权限），不能用历史端口重开规则误限 SS。

### 不重装调整

以下均以 root 执行，无需安装器原文件，不重启 sing-box、不更换节点凭据：

```sh
hy2-limit status          # 保存状态、规则所有权及 tc 计数；缺失/被改动时报错
hy2-limit set 80          # HY2 总发送上限改为 80 Mbps，并保存
hy2-limit off             # 仅关闭发送限速；local 跳跃保留并继续开机恢复
hy2-limit disable-all     # 同时关闭限速、移除经完整指纹验证的自有跳跃表；切换 SS/Reality 前使用
hy2-limit set 100         # 使用保存的本机端口重新开启
# 网卡迁移需明确指定，仍按保守队列检查执行：
VPS_SHAPING_INTERFACE=eth0 hy2-limit set 100
```

### 作用范围与限制

- 限的是 **VPS 发往 HY2 客户端**的 UDP 协议流量（包括协议开销），external 匹配本机 listen，local 匹配合并后的跳跃范围与 listen 并集，不是网站→VPS 的接收流量；不设置 ingress police、不建立 IFB。不包括同一客户端另外使用的 REALITY 流量，也不对 SS/SSH/系统更新设速率上限。
- 全部客户端共享一个 TBF；external 商家多对一 NAT 在本 namespace 外，仍只匹配本机监听端口；local 模式会匹配 `HY2_SERVER_PORTS` 与监听端口的并集。这是单网卡、单本机 HY2 UDP 监听器方案，不是多出口流量覆盖保证；策略路由、隧道及自动选择不到的出口需人工确认，默认路由歧义必须显式指定网卡。
- 本机 REDIRECT 的反向 NAT 可能在 tc 前将源端口改为公网跳跃端口；local 不只豁免 NAT，而是将**全部跳跃区间及 listen**的 IPv4/IPv6 UDP flower 分类器接到同一 TBF。最多 64 个合并区间、128 个分类器；Linux flower 不支持源端口范围时明确失败并尝试恢复，不逐端口降级、不用第三方 mark。UDP 分类并非进程鉴权，其他程序使用范围内源端口也会被分类，应避免与其他 UDP 服务范围重叠。同数字 TCP（Reality/SSH）不匹配。
- NAT 检查目前只信任完整指纹匹配的脚本 `inet hy2_hopping` 表；**其他本机 nft NAT 链或 legacy iptables NAT 规则仍保守拒绝启用/恢复限速，包括可能无关的 Docker NAT**。没有宣称已分析无关 NAT 的安全性。local 跳跃即使不开启限速，新增、更新、重建规则前也执行相同 NAT 安全检查。`off` 仅撤销限速且不改已有 NAT 时允许清理，`disable-all` 撤销自有规则不会因第三方 NAT 而被阻挡；但不能借 `off` 绕过检查创建或重建跳跃规则。关闭限速不会因新出现第三方 NAT 而阻止撤销自有限速。
- 队列架构为 root prio（三个 band，16 项 priomap 全为 1，未匹配默认进入 band2）+ band3 单一 TBF；IPv4/IPv6 flower 以 `ip_proto udp` 和上述 `src_port` 区间匹配，使用 `skip_hw`。不改变接收方向，不设置整机根限速。prio 是严格优先级，其他持续发送可能饿死 HY2；限速只是**上限，不保证最低速度**。未限速流量仍会经过新调度器，不能理解为调度时序完全不变。
- TBF burst 按速率约 10ms 的字节数计算，夹在 16KiB 到 12.5MB，适合常见 HZ≥100；短时可突发，100ms 排队延迟不是精确应用带宽保证。Mbps 为十进制兆比特/秒，100 Mbps 约等于 12.5 MB/s（未扣开销）。
- UDP 源端口分类不是进程身份认证；其他程序若复用同一 UDP 源端口也可能被归类。IPv6 扩展头、分片、封装及驱动/内核解析能力存在边界，不能承诺任意非标准包绝无漏匹配；本机回环自检不验证公网 tc 吞吐。部署后需用 `hy2-limit status` 的计数及真实双栈客户端流量验证。

### 队列所有权、持久化与失败处理

验证范围：已在 Windows portable Bash 的隔离命令 mocks 中回归；未验证真实 Linux 内核、真实 nft/tc JSON 差异、双栈公网连通性或吞吐，请先在可救援测试 VPS 验证。

只接管明确识别的原生 `handle 0:` 单根 `fq_codel` / `pfifo_fast` / `fq`；拒绝自定义、多队列、noqueue、已有 ingress/clsact、已有根过滤器，以及任何无法读取的状态。不会无条件 `replace` 或删除陌生规则。模块记录自己的 qdisc/class/filter 无统计快照，更新/关闭前必须完全匹配；记录时也核对固定 handle/pref/kind，避免将可识别的陌生对象纳入所有权。进程内快照用于指纹文件写失败时的补偿，外部修改后宁可失败保留现场。检查与变更仍存在并发窗口，请勿与其他 tc 管理器同时操作，模块内操作使用 flock 串行化。

关闭时仅删除经所有权检查的本模块根队列，**由内核重新附加当前设备原生默认队列**；不恢复原队列的积压、统计或调参，不宣称完整恢复任何自定义队列。启用失败/更新失败会尝试撤销本模块规则并恢复旧保存状态；原来已开启则尽力重建旧规则并报告结果。外部规则冲突、设备消失或内核错误可能使回滚失败。如果创建规则后无法读取快照，不能安全识别自有部分，模块会保留现场；本次要求开启或原来已开启且保护恢复失败时，会停止整个 sing-box（`both` 的 REALITY 也随服务停止）以免假保护运行，安装器不会又自动重启旧服务。错误会明确要求人工检查，不能把失败当成功。

helper 位于 `/usr/local/sbin/hy2-limit`（独立运行，root:root 700），入口为 `/usr/local/bin/hy2-limit`；保存 JSON 为 `/etc/hy2-limit/state.json`（目录 700、文件 600），易失规则指纹为 `/run/hy2-limit-live.json`（600）。严格校验所有者/权限/字段，不 source 状态文件。保存状态 v1 会按 external 单监听语义读取，下一次成功写入迁移为 v2。服务和 wrapper 保持原 v1 精确内容；只有完整旧 v1 helper 的受信 SHA-256 白名单允许升级，先独立随机命名备份再覆盖，未知内容/所有者/权限/符号链接一律拒绝，失败恢复旧 helper；不是凭文件名或注释认领。systemd 使用 `hy2-limit.service` 及 sing-box 的专用 drop-in，在启动 sing-box 前恢复并检查；OpenRC 使用独立服务依赖及 start_pre，保护失败阻止启动；已有规则的恢复快路仍复核当前 HY2 配置、接口及本机 NAT。NAT 持久结构指纹在 `/etc/hy2-limit/nat.json`（600），仅允许自身 table/chain/comment/完整规则匹配（忽略内核动态 handle/index）。规则变化拒绝更新/删除，同名陌生对象没有指纹也拒绝；重启表缺失时重建。nft 批处理原子更新；主机已有连接的 conntrack 不会被清空，改范围/切模式后已有流的 NAT 可能持续到超时，新连接使用新规则。`off` 后仍保留 local 跳跃并恢复；完全关闭（external 且 limiter disabled）后服务/helper 惰性，重启不重新启用，restore 不依赖 tc/ip。安装须在应用限速和规则复核成功后才接受新配置；失败尝试恢复旧状态/旧配置。不是对断电、SIGKILL 或任意第三方网络更改的完整事务保证。

### 修改范围或模式时的旧连接

脚本不会清空系统 conntrack，以免中断其他服务。修改跳跃范围或从 local 切换为 external 后，已有连接可能在超时前继续使用旧的 NAT 源端口，而限速分类按新范围生成；因此不能保证切换期间这些旧连接始终受新限速规则覆盖。正式使用时不要带着活跃客户端直接切换范围或模式；应先停止客户端连接，确认旧连接跟踪条目已失效后再变更，并重新连接验证。单纯通过 `hy2-limit set` 调整速率、不改变端口范围和模式，不涉及此范围变化问题。

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

`shownode` 和安装终端中的节点 JSON 不含外层 `[]`，每个节点对象的 `{` 前有四个空格，内部每层增加两个空格，末尾输出 `},`，便于粘贴到已有的 `outbounds` 数组中。如果它是数组最后一项，请删除末尾逗号，标准 JSON 不允许尾随逗号。文件 `client-outbounds.json` 仍保留合法 JSON 数组格式，完整手机配置文件也保持可直接导入。

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
| `/usr/local/sbin/hy2-limit`、`/usr/local/bin/hy2-limit` | 可选 HY2 聚合发送限速的独立 helper 与命令入口 |
| `/etc/hy2-limit/state.json`、`/etc/hy2-limit/nat.json`、`/run/hy2-limit-live.json` | HY2 v2 保存设置、持久 NAT 完整指纹与当前启动周期 tc 指纹（均 600） |
| `/etc/systemd/system/hy2-limit.service`、`sing-box.service.d/hy2-limit.conf` 或 `/etc/init.d/hy2-limit` | 可选 HY2 限速持久化及启动保护 |
| `/usr/local/bin/sshkey` | 私钥查看 / 确认删除工具 |

具体证书目录及本次输出以脚本终端提示为准。
