# 广东电信/移动低流量 TcpQuality 前后对比

本目录包含一个基于 [ibsgss/TcpQuality](https://github.com/ibsgss/TcpQuality) 的专用版本，源代码对应上游提交 `6017af3fcb83b300b9a15b058d58062551d1c682`。保留上游许可证，见本目录 `LICENSE`；新增 `--gd-proxy-only` 专用模式，限制测试范围。

## 测试范围

- 广东电信、移动的 IPv4 普通回程。
- 广东电信、移动的 IPv4 大包回程。
- VPS → 广东的电信、移动单线程下载测速。
- 每个运营商、每轮下载最多 64 MiB；同时设 10 秒超时。前后两轮理论下载载荷上限约 256 MiB，实际可能更少。

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

# 自动准备依赖，然后测调优前基线
/root/tq-gd.sh baseline

# 只做 tcpfit 基础调优；200 替换成套餐已知带宽 Mbps
/root/tq-gd.sh tune 200

# 调优后复测并比较
/root/tq-gd.sh after
/root/tq-gd.sh compare
```

`tune 200` 等价于 `tcpfit tune --role proxy --bw 200`：固定代理用途和已知带宽，只做基础调优，不执行 iperf 带宽探测、自动调优或拐点扫描。带宽必须是已知数值，不要写 `auto`。脚本采用一次性标记，防止误跑重复调优或重复测速。

## 流量预算与数据保存

每轮单线程下载的最大 payload 是 2 个运营商 × 64 MiB；两轮最多约 256 MiB，另有小量回程探测、脚本/节点列表下载、协议开销和可能重传。安装系统依赖和 NextTrace/Tcpfit 工具的流量另计。此限制不是 VPS 全局流量硬封顶，也不等于供应商计费保证；测试时避免其他并发下载。

结果默认保存在 `/root/tcpquality-gd-compare/`，包括基线/调优后 CSV、完整日志、时间戳、流量计数及 `tune.done` 标记。可以设置 `TCPQUALITY_GD_DATA_DIR` 更换目录。

如需重开一组：先备份结果；如要恢复系统到首次调优前，先运行 `tcpfit rollback`，再执行：

```sh
RESET=YES /root/tq-gd.sh reset
```

reset 只删除比较数据，不会卸载 TcpQuality/tcpfit，也不会回滚系统 TCP 配置。
