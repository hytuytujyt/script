# 广东电信/移动低流量 TcpQuality 前后对比

本目录包含一个基于 [ibsgss/TcpQuality](https://github.com/ibsgss/TcpQuality) 的专用版本，源代码对应上游提交 `6017af3fcb83b300b9a15b058d58062551d1c682`。保留上游许可证，见本目录 `LICENSE`；新增 `--gd-proxy-only` 专用模式，限制测试范围。

## 测试范围

- 广东电信、移动的 IPv4 普通回程。
- 广东电信、移动的 IPv4 大包回程。
- VPS → 广东的电信、移动单线程下载测速。
- 单线程下载总预算按调优前、调优后两轮合计设置，可设 32–2048 MiB（4 的倍数），默认 128 MiB。预算平均分配给四次下载（两个运营商 × 两轮）；每次另有 10 秒超时，实际通常更少。

不测联通、其他地区、IPv6、上传、教育网、国际互联、Apple CDN；不上传测试报告或参与测速排名。未能获取广东地区对应运营商测速节点时会报错，不回退到其他地区。

网卡 RX+TX 计数会记录在结果文件中，但包含 VPS 上其他并发流量，也不保证等于商家计费字节。

## 自动准备与操作流程

以 root 在 Linux VPS 上运行。需要 Bash 与网络连接。首次执行 `baseline` 会：

1. 检查并询问是否自动安装缺少的系统工具。
2. 安装 NextTrace Tiny（用于大包回程识别），下载 TcpQuality core 并校验 SHA256。
3. 如系统没有 tcpfit，下载官方 v0.5.9 脚本并校验 SHA256 后安装到 `/usr/local/bin/tcpfit`。
4. 完成上述准备后才开始基线测试。

支持 Debian/Ubuntu 和 Alpine 的系统依赖安装。包管理器下载会消耗额外流量，**不包含在测速载荷上限内**；脚本会在安装前显示计划并要求确认。拒绝后不会开始测速。普通测试阶段不会安装软件包。

```sh
curl -fsSL https://raw.githubusercontent.com/hytuytujyt/script/main/tcpquality-gd/run.sh -o /root/tq-gd.sh
chmod 700 /root/tq-gd.sh

# 只自动安装/检查，不开始测试（可选）
/root/tq-gd.sh setup

# 自动准备依赖；交互设置基线+调优后两轮的下载总预算，默认128MiB
/root/tq-gd.sh baseline
# 也可指定两轮总量：512MiB总预算，四次下载各最多128MiB
# /root/tq-gd.sh baseline 512

# 只做 tcpfit 基础调优；200 替换成套餐已知带宽 Mbps
/root/tq-gd.sh tune 200

# 调优后复测并比较
/root/tq-gd.sh after
/root/tq-gd.sh compare
```

`baseline` 会询问调优前+调优后两轮的单线程下载载荷总预算，默认 128 MiB，须为 4 的倍数；也可用 `baseline 512` 或 `TQ_SPEEDTEST_BUDGET_MIB=512 /root/tq-gd.sh baseline` 设置。`after` 自动沿用该预算。预算四等分给四次下载：128 MiB 意味每次最多 32 MiB；512 MiB 意味每次最多 128 MiB。它不是全机网络流量硬上限。

`tune 200` 等价于 `tcpfit tune --role proxy --bw 200`：固定代理用途和已知带宽，只做基础调优，不执行 iperf 带宽探测、自动调优或拐点扫描。带宽必须是已知数值，不要写 `auto`。脚本采用一次性标记，防止误跑重复调优或重复测速。

## 流量预算与数据保存

用户设置的总预算分配到四个下载对象（两个运营商 × 两轮），每次最多为总预算的四分之一；另有少量回程探测、脚本/节点列表下载、协议开销及可能重传。安装系统依赖和 NextTrace/Tcpfit 工具的流量单独记录。脚本最后会列出准备工具、调优前测试、tcpfit 基础调优、调优后测试各阶段的网卡 RX+TX 增量及合计。计数包含并发流量，不是全机流量硬封顶，也不保证等于供应商账单。

结果默认保存在 `/root/tcpquality-gd-compare/`，包括预算设置、基线/调优后 CSV、完整日志、时间戳、分阶段流量计数及 `tune.done` 标记。可以设置 `TCPQUALITY_GD_DATA_DIR` 更换目录。

如需重开一组：先备份结果；如要恢复系统到首次调优前，先运行 `tcpfit rollback`，再执行：

```sh
RESET=YES /root/tq-gd.sh reset
```

reset 只删除比较数据，不会卸载 TcpQuality/tcpfit，也不会回滚系统 TCP 配置。
