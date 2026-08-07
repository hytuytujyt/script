# sing-box Reality 一键安装脚本

在任意 Linux 服务器一键部署 [sing-box](https://sing-box.app/) VLESS-REALITY 代理，自动安装依赖、配置服务端、放行防火墙、配好日志轮转，并生成客户端节点（链接 / JSON / YAML 三种格式）。

## 一、安装

一条命令自动完成：**补依赖 → 装 sing-box → 生成节点**。脚本会自动挑选可用的下载器（wget → curl → busybox wget），任意系统任一搭配都能取到脚本：

```bash
{ command -v wget >/dev/null 2>&1 && wget -qO- https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh || command -v curl >/dev/null 2>&1 && curl -fsSL https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh || command -v busybox >/dev/null 2>&1 && busybox wget -qO- https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh ; } | LISTEN_PORT=x SERVER_IP=y NODE_NAME=z sh
```

> 原理：`&&`/`||` 链会从左到右找第一个存在的下载器。只装了 curl 的 Debian、只剩 busybox 的精简 Alpine，都能命中对应分支。

脚本会自动识别系统并安装缺少的 bash / curl：

| 系统             | 包管理器 | 是否需要手动装依赖 |
|------------------|----------|--------------------|
| Alpine           | apk      | ❌ 自动安装        |
| Debian / Ubuntu  | apt      | ❌ 自动安装        |
| Fedora / RHEL9+  | dnf      | ❌ 自动安装        |
| CentOS7 / RHEL7  | yum      | ❌ 自动安装        |
| openSUSE / SLES  | zypper   | ❌ 自动安装        |
| Arch             | pacman   | ❌ 自动安装        |

> 说明：新装 VPS 通常已自带 bash 和 curl（直接跳过多余步骤）；只有精简 Alpine / 容器环境才需要自动补齐，脚本已处理。
>
> **关于精简/改装系统**：脚本引导段在 debian/ubuntu 上会自动用 apt 装齐 bash+curl；在 Alpine 上即便没有 curl，引导段也会先装好再自举。取脚本这一步若 wget/curl 都缺，还会尝试 `busybox wget` 兜底。

### 前置要求

- 需要 **root** 权限
- 确保 **端口（默认 443，或 NAT 映射的外部端口）未被占用**

## 常见问题（排障）

| 报错 | 原因 | 处理 |
|------|------|------|
| `wget: command not found` / `curl: command not found` | 精简系统没装该工具 | 换用上面的多功能一条命令（会自动换下载器）；或先装再跑：Debian/Ubuntu `apt-get install -y curl`，Alpine `apk add curl` |
| 一键命令执行后 `〔!〕未识别的包管理器` | 引导段没识别到熟悉的包管理器 | 按脚本提示手动装好 bash 和 curl 后重跑 |
| 下载 sing-box 报 `certificate verify failed` / SSL 错误 | 系统缺 ca-certificates | 装证书：Debian `apt-get install -y ca-certificates`，Alpine `apk add ca-certificates`，然后重跑 |
| 装完后连不上 | 云厂商安全组没放行端口 | 到云控制台放行 443（NAT 机器放行映射的外部端口） |
| 节点连不上但机器能 SSH 登录 | sing-box 进程挂了或 NAT 映射异常 | `rc-service sing-box status` + `netstat -tln \| grep :443` 确认进程与监听；再用 `log` 看日志 |

## 二、参数说明

| 环境变量       | 含义                                                                                 | 示例                      |
|----------------|--------------------------------------------------------------------------------------|---------------------------|
| `LISTEN_PORT=x` | **NAT 机器**：填映射后的外部端口号；非 NAT 或 IPv6-only 填 `0`（自动用 443）        | `LISTEN_PORT=62879` 或 `LISTEN_PORT=0` |
| `SERVER_IP=y`   | 服务器的**公网 IP**                                                                  | `SERVER_IP=45.207.35.102` |
| `NODE_NAME=z`   | 节点名（YAML 与 vless 链接里显示，可带 emoji）                                      | `NODE_NAME=lzycat🇯🇵` |

可选参数（一般不需要改）：

| 环境变量                   | 默认值                 | 说明                      |
|----------------------------|------------------------|---------------------------|
| `REALITY_DEST`             | `addons.mozilla.org:443` | 伪装握手目标             |
| `REALITY_SERVER_NAME`      | `addons.mozilla.org`     | TLS SNI                  |
| `SCRIPT_URL`               | 本仓库脚本地址          | 自举重新拉取时使用的地址 |

## 三、运行后

### 查看节点

```bash
shownode
```

> 需要**重新连接 SSH**（或执行 `source ~/.bashrc`）后才能生效。节点信息也会保存在 `/etc/sing-box/node_output.txt`，可直接 `cat` 查看。输出包含 **vless 链接 + 客户端 config.json + Clash/Mihomo YAML** 三种格式。

### 查看日志

```bash
log
```

> 显示 sing-box 最近 100 行日志，并列出轮转归档文件。日志写入 `/var/log/sing-box.log`，级别 `warn`（只记错误与恶意探测，噪音小）。

### 日志轮转（自动配置，无需手动）

- 单文件超过 **10M** 或**每日**轮转一次，保留 3 份并压缩，占用上限约 30M
- 看历史归档：`zcat /var/log/sing-box.log.1.gz`

### 放行端口

脚本会自动处理系统内防火墙（ufw / firewalld）。若还连不上，请到**云厂商控制面板的安全组**，放行对应端口：

- 非 NAT：放行 **443**
- NAT 机器：放行你映射的**外部端口**

## 四、客户端

脚本输出的 vless:// 链接可直接导入客户端（V2RayN / sing-box / NekoBox 等）；`shownode` 里另附 **Clash / Mihomo 的 YAML proxy 段**，直接粘进配置的 `proxies:` 下即可使用。
