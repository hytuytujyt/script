# sing-box Reality 一键安装脚本

在任意 Linux 服务器一键部署 [sing-box](https://sing-box.app/) VLESS-REALITY 代理，自动安装依赖、配置服务端、放行防火墙并生成客户端节点。

## 一、安装

一条命令，自动完成：**补依赖 → 装 sing-box → 生成节点**。

```bash
wget -qO- https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh | LISTEN_PORT=x SERVER_IP=y sh
```

> 若机器已有 curl（非精简系统），也可用 `curl -fsSL ... | LISTEN_PORT=x SERVER_IP=y sh`。

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

### 前置要求

- 需要 **root** 权限
- 确保 **端口（默认 443，或 NAT 映射的外部端口）未被占用**

## 二、参数说明

| 环境变量       | 含义                                                                                 | 示例                      |
|----------------|--------------------------------------------------------------------------------------|---------------------------|
| `LISTEN_PORT=x` | **NAT 机器**：填映射后的外部端口号；非 NAT 或 IPv6-only 填 `0`（自动用 443）        | `LISTEN_PORT=62879` 或 `LISTEN_PORT=0` |
| `SERVER_IP=y`   | 服务器的**公网 IP**                                                                  | `SERVER_IP=45.207.35.102` |

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

> 需要**重新连接 SSH**（或执行 `source ~/.bashrc`）后才能生效。节点信息也会保存在 `/etc/sing-box/node_output.txt`，可直接 `cat` 查看。

### 放行端口

脚本会自动处理系统内防火墙（ufw / firewalld）。若还连不上，请到**云厂商控制面板的安全组**，放行对应端口：

- 非 NAT：放行 **443**
- NAT 机器：放行你映射的**外部端口**

## 四、客户端

脚本输出的 vless:// 链接及 sing-box 客户端 config.json 可直接导入客户端（V2RayN / sing-box / NekoBox 等）使用。