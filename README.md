# REALITY / Shadowsocks / HY2 一键安装

sing-box 节点安装脚本，root 执行。结束时终端打印的内容就是客户端配置。

```sh
curl -fsSL https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh -o /tmp/install_reality.sh
```

`SERVER_IP` 必填，其余参数不填都有默认值。示例 IP `203.0.113.10` 换成自己的公网 IP。

## 选模式

| MODE | 安装内容 | 传输 | 需要放行 |
| --- | --- | --- | --- |
| `reality`（默认） | VLESS + REALITY + Vision | TCP | `LISTEN_PORT` TCP |
| `ss` | Shadowsocks | TCP + UDP | `LISTEN_PORT` TCP + UDP |
| `hy2` | Hysteria2 | UDP | `HY2_SERVER_PORTS` UDP |
| `both` | REALITY + HY2 | TCP + UDP | 两者 |

**端口规则**：`ACTUAL_LISTEN_PORT` 是本机端口，`LISTEN_PORT` 是公网端口。

- 普通 VPS：两者填一样，在系统防火墙或云安全组放行。
- 商家 NAT：两者不同，先在商家面板把公网端口映射到本机端口，再执行。

下面命令均为普通 VPS 写法。

## REALITY

```sh
MODE=reality SERVER_IP=x.x.x.x ACTUAL_LISTEN_PORT=443 LISTEN_PORT=30116 sh /tmp/install_reality.sh
```

## Shadowsocks

```sh
MODE=ss SERVER_IP=x.x.x.x ACTUAL_LISTEN_PORT=443 LISTEN_PORT=30116 sh /tmp/install_reality.sh
```

## HY2

HY2 的端口含义不同：

- `HY2_LISTEN_PORT`：本机实际监听的唯一 UDP 端口。
- `HY2_SERVER_PORTS`：手机连接的公网 UDP 端口，单个、范围 `30000-30005`、逗号列表 `30000,40006` 均可。
- `HY2_PORT_HOPPING_MODE`：转发由谁做。`local` 由脚本在本机建转发，用于没有商家映射的普通公网 VPS；`external` 由商家面板映射或直连，脚本不碰网络规则（默认）。

手机在 `HY2_SERVER_PORTS` 里轮换端口，所有入口最终都落到同一个 `HY2_LISTEN_PORT`。

**普通 VPS，开启跳跃**（放行 UDP 30000–30005）：

```sh
MODE=hy2 SERVER_IP=203.0.113.10 HY2_LISTEN_PORT=30000 HY2_SERVER_PORTS=30000-30005 HY2_PORT_HOPPING_MODE=local sh /tmp/install_reality.sh
```

**商家 NAT，开启跳跃**：先在面板把公网 UDP 30000–30005 全部映射到本机同一个 UDP 20116。

```sh
MODE=hy2 SERVER_IP=203.0.113.10 HY2_LISTEN_PORT=20116 HY2_SERVER_PORTS=30000-30005 sh /tmp/install_reality.sh
```

`HY2_PORT_HOPPING_MODE` 默认即 `external`，可省略。

**单端口，不跳跃**：两个端口填同一个，不需要任何转发。普通 VPS 放行 UDP 30000；商家 NAT 则 `HY2_LISTEN_PORT` 填本机端口、`HY2_SERVER_PORTS` 填公网端口。

```sh
MODE=hy2 SERVER_IP=203.0.113.10 HY2_LISTEN_PORT=30000 HY2_SERVER_PORTS=30000 sh /tmp/install_reality.sh
```

## REALITY + HY2

普通 VPS（放行 TCP 20116 和 UDP 30000–30005，HY2 用 `local` 本机转发）：

```sh
MODE=both SERVER_IP=203.0.113.10 ACTUAL_LISTEN_PORT=20116 LISTEN_PORT=20116 HY2_LISTEN_PORT=30000 HY2_SERVER_PORTS=30000-30005 HY2_PORT_HOPPING_MODE=local sh /tmp/install_reality.sh
```

商家 NAT（面板映射公网 TCP 30116 → 本机 20116，公网 UDP 30000–30005 → 本机同一 UDP 20116，HY2 用 `external`，脚本不建转发）：

```sh
MODE=both SERVER_IP=203.0.113.10 ACTUAL_LISTEN_PORT=20116 LISTEN_PORT=30116 HY2_LISTEN_PORT=20116 HY2_SERVER_PORTS=30000-30005 HY2_PORT_HOPPING_MODE=external sh /tmp/install_reality.sh
```

TCP 和 UDP 可以使用相同端口号。

## 参数

| 参数 | 说明 | 默认 |
| --- | --- | --- |
| `MODE` | `reality` / `ss` / `hy2` / `both` | `reality` |
| `SERVER_IP` | 节点公网 IP，**必填** | 无 |
| `ACTUAL_LISTEN_PORT` | REALITY / SS 本机端口 | 无 |
| `LISTEN_PORT` | REALITY / SS 公网端口 | 无 |
| `HY2_LISTEN_PORT` | HY2 本机 UDP 端口 | 同 `ACTUAL_LISTEN_PORT` |
| `HY2_SERVER_PORTS` | HY2 公网 UDP 端口，单端口 / 范围 / 逗号列表 | 同 `LISTEN_PORT` |
| `HY2_PORT_HOPPING_MODE` | `local` 本机转发，`external` 商家映射或直连 | `external` |
| `HY2_HOP_INTERVAL` | 跳跃间隔，单端口时无意义 | `30s` |
| `HY2_OBFS` | 混淆方式 `gecko` / `salamander` / `none` | `gecko` |
| `HY2_HOPPING_INTERFACE` | 自动识别网卡失败时手动指定，如 `ens3` | 自动 |
| `NODE_NAME` | 节点名称，含空格用引号 | `<MODE>-<主机名>` |

范围也可写成 `30000:30005`。只填商家允许的端口，避免与其他 UDP 服务冲突。

## 安装后

```sh
cat /etc/sing-box/node_output.txt
```

重新登录后直接执行 `shownode` 效果相同。完整客户端配置在 `/etc/sing-box/client.json`，单协议配置为 `client-reality.json` / `client-ss.json` / `client-hy2.json`（按所选模式生成）。这些文件含密码，不要公开。

## 低流量 VPS 对比测试（独立工具）

`tcpquality-gd/` 是与节点安装器分开的 TcpQuality 专用副本，只测广东电信、移动 IPv4 普通/大包回程，以及 VPS → 广东的单线程下载；不测联通、IPv6、上传、其他地区、教育网、国际互联或 Apple CDN。单线程下载总预算按**基线与调优后两轮合计**设置，范围 32–2048 MiB（4 的倍数），默认 128 MiB；四个下载平均分配，每次另有 10 秒超时，因此实际通常更少。工具安装、协议开销、其他 VPS 流量和商家计费口径不包含在 payload 预算内，所以不是全机流量硬限制或计费保证。

**脚本会自动准备依赖**：首次运行时检查系统工具，支持 Debian/Ubuntu 和 Alpine；缺少时会先列出要安装/下载的项目并询问确认，然后安装系统依赖、NextTrace Tiny、tcpfit v0.5.9，并下载及校验 TcpQuality core 和 tcpfit 的 SHA256。缺少大包回程所需工具时不会静默跳过。依赖安装本身也会消耗流量，请在确认前考虑退款额度。需要 Bash、root 权限和网络连接。

### 流程

```sh
# 下载运行器（这一步需要 curl）
curl -fsSL https://raw.githubusercontent.com/hytuytujyt/script/main/tcpquality-gd/run.sh -o /root/tq-gd.sh
chmod 700 /root/tq-gd.sh

# 自动安装缺少的依赖/工具；交互设置基线+调优后两轮的总预算（默认128MiB）
/root/tq-gd.sh baseline
# 也可直接指定两轮总预算，例如512MiB：四个下载各最多128MiB
# /root/tq-gd.sh baseline 512

# 只做基础调优：带宽填套餐已知 Mbps 数值，例如 200；不运行 iperf 测速或拐点扫描
/root/tq-gd.sh tune 200

# 调优后复测与前后对比
/root/tq-gd.sh after
/root/tq-gd.sh compare
```

`baseline` 会交互询问基线+调优后两轮的单线程下载总预算，默认 128 MiB，范围 32–2048 MiB 且必须为 4 的倍数；也可用 `baseline 512` 或 `TQ_SPEEDTEST_BUDGET_MIB=512` 指定。预算四等分到四次下载：例如 128 MiB 总预算即每次最多 32 MiB；512 MiB 总预算即每次最多 128 MiB。`after` 自动复用该预算。预算只限制四个单线程下载对象，不包含路由探测、工具安装、协议开销或其他后台流量。脚本会在最后显示基线测试、tcpfit 调优、调优后测试及准备工具阶段的网卡 RX+TX 计数和合计；该计数含并发流量，不能等同商家账单。

首次运行会询问是否安装缺少的工具；拒绝安装时不会开始测试。`tune 200` 会使用 proxy 角色执行 `tcpfit tune --role proxy --bw 200`；数字必须换成该 VPS 的实际已知带宽，不能留空或写 `auto`。若已有 tcpfit，脚本沿用已有版本；没有时会安装经过 SHA256 校验的官方 v0.5.9 到 `/usr/local/bin/tcpfit`。不需要再手工进入菜单，也不要选一键调优或 sweep。

日志和 CSV 默认保存在 `/root/tcpquality-gd-compare/`。基线、基础调优和调优后测试各有一次性保护，避免误重复测速。确需重开一组时先备份结果，再运行 `tcpfit rollback`（如需恢复初始网络参数），然后显式执行 `RESET=YES /root/tq-gd.sh reset`；reset 只删比较记录，不会卸载依赖或回滚 tcpfit。退款流量额度紧张时不要运行拐点扫描，它可能消耗 GB 级流量；应先查看 tcpfit 给出的估算。

## 关闭 SSH 密码登录（可选，脚本不会自动做）

先执行 `sshkey` 保存私钥，并在另一个窗口确认能用它登录，同时保留当前会话和服务商救援控制台。然后：

```sh
closepwd
```

阅读提示后输入 `CLOSE` 确认。命令会备份 SSH 主配置、关闭 `PasswordAuthentication` 和 `KbdInteractiveAuthentication` 并重启 SSH，失败自动恢复；未启用公钥认证、配置检查失败或检测到 `Match` 规则时拒绝执行。

## 注意事项

- **重跑会覆盖除 Argo 外的入站节点并重新生成凭据**，请使用本次输出的配置。
- HY2 证书自签并内嵌客户端，无需域名或 Cloudflare API；有效期 36 个月，同 SNI 重装会复用，替换下的旧证书留在 `/etc/sing-box/hy2-tls/`。客户端不支持 gecko 时加 `HY2_OBFS=salamander` 并用新配置。
- 已装 sing-box 低于 **1.12.0** 会被自动换成最新版（生成的配置使用 1.12 起的 DNS/route 写法）。不想自动升级请先自行升级。
- 已存在的 `/etc/systemd/system/sing-box.service` 会备份为 `sing-box.service.pre-installer`（仅一次）。
- 本机转发需要 nftables、CAP_NET_ADMIN 和 systemd/OpenRC；检测到旧版网络集成状态时脚本会停止并提示人工检查。
- 云安全组需自行放行。不要为安装删除已有网络规则或 SSH 端口映射。
- 修改跳跃范围或 `local` / `external` 前先断开客户端，否则旧连接可能沿用旧转发。
- **本机转发的端到端验证尚未完成**（已通过语法、配置生成与规范化回归测试）；SSH 关闭功能也未在 Linux VPS 上实测。请在可救援的机器上先测试。
