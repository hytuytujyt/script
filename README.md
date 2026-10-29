# REALITY / Shadowsocks / HY2 一键安装

root 执行。先下载脚本，再复制对应模式的命令执行。示例 IP `203.0.113.10` 换成自己的公网 IP。

- **普通 VPS**：直接在系统或云安全组放行所用端口。
- **商家 NAT**：先在商家面板做端口映射，再执行安装命令。
- **重跑会覆盖除 Argo 外的入站节点并重新生成凭据**，安装后请使用本次输出的客户端配置。

| MODE | 安装内容 | 传输 |
| --- | --- | --- |
| `reality`（默认） | VLESS + REALITY + Vision | TCP |
| `ss` | Shadowsocks | TCP / UDP |
| `hy2` | Hysteria2 | UDP |
| `both` | REALITY + HY2 | TCP + UDP |

## 第一步：下载

```sh
if command -v curl >/dev/null 2>&1; then
  curl -fL --connect-timeout 10 -m 60 -o /tmp/install_reality.sh \
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

## 第二步：按模式执行

### REALITY

两个端口变量的含义：`ACTUAL_LISTEN_PORT` 是**本机端口**，`LISTEN_PORT` 是**公网端口**。

普通 VPS，两者填一样，放行 TCP 20116：

```sh
MODE=reality \
SERVER_IP=203.0.113.10 \
ACTUAL_LISTEN_PORT=20116 \
LISTEN_PORT=20116 \
NODE_NAME='我的REALITY' \
sh /tmp/install_reality.sh
```

商家 NAT，例如公网 TCP 30116 → 本机 20116：

```sh
MODE=reality \
SERVER_IP=203.0.113.10 \
ACTUAL_LISTEN_PORT=20116 \
LISTEN_PORT=30116 \
NODE_NAME='我的REALITY' \
sh /tmp/install_reality.sh
```

### Shadowsocks

变量含义与 REALITY 相同。普通 VPS 放行 TCP 和 UDP 20116：

```sh
MODE=ss \
SERVER_IP=203.0.113.10 \
ACTUAL_LISTEN_PORT=20116 \
LISTEN_PORT=20116 \
NODE_NAME='我的SS' \
sh /tmp/install_reality.sh
```

商家 NAT，例如公网 TCP/UDP 30116 → 本机 20116：

```sh
MODE=ss \
SERVER_IP=203.0.113.10 \
ACTUAL_LISTEN_PORT=20116 \
LISTEN_PORT=30116 \
NODE_NAME='我的SS' \
sh /tmp/install_reality.sh
```

### HY2 端口跳跃

HY2 的端口变量含义不同：

- `HY2_LISTEN_PORT`：Hy2 程序**实际监听的唯一本机 UDP 端口**，只填一个。
- `HY2_SERVER_PORTS`：**手机访问的公网 UDP 端口**，可以是一个端口或一段范围。
- `HY2_PORT_HOPPING_MODE`：决定**转发由谁来做**。`local` 由脚本在这台 VPS 本机建立转发规则，用于没有商家映射的普通公网 VPS；`external` 表示转发由商家面板完成或端口直连，脚本不碰网络规则（默认值）。

跳跃的原理：手机在 `HY2_SERVER_PORTS` 范围内换端口，所有入口最终都交给同一个 `HY2_LISTEN_PORT`。

普通 VPS 用 `local`，脚本自动建立本机转发，放行 UDP 30000–30005：

```sh
MODE=hy2 \
SERVER_IP=203.0.113.10 \
HY2_LISTEN_PORT=30000 \
HY2_SERVER_PORTS=30000-30005 \
HY2_PORT_HOPPING_MODE=local \
HY2_HOP_INTERVAL=30s \
ENABLE_VPS_SHAPING=1 \
VPS_UPLOAD_MBIT=100 \
NODE_NAME='我的HY2' \
sh /tmp/install_reality.sh
```

商家 NAT 用 `external`，先在面板把公网 UDP 30000–30005 **全部映射到本机同一个 UDP 20116**：

```sh
MODE=hy2 \
SERVER_IP=203.0.113.10 \
HY2_LISTEN_PORT=20116 \
HY2_SERVER_PORTS=30000-30005 \
HY2_PORT_HOPPING_MODE=external \
HY2_HOP_INTERVAL=30s \
ENABLE_VPS_SHAPING=1 \
VPS_UPLOAD_MBIT=100 \
NODE_NAME='我的HY2' \
sh /tmp/install_reality.sh
```

### HY2 单端口（不跳跃）

不需要跳跃时省略 `HY2_HOP_INTERVAL` 和 `HY2_PORT_HOPPING_MODE`（默认 `external`，脚本不创建本机转发）。

普通 VPS：两个端口填一样，放行 UDP 30000。

```sh
MODE=hy2 \
SERVER_IP=203.0.113.10 \
HY2_LISTEN_PORT=30000 \
HY2_SERVER_PORTS=30000 \
ENABLE_VPS_SHAPING=1 \
VPS_UPLOAD_MBIT=100 \
NODE_NAME='我的HY2' \
sh /tmp/install_reality.sh
```

商家 NAT：`HY2_LISTEN_PORT` 填本机端口，`HY2_SERVER_PORTS` 填商家映射的公网端口，两者通常**不同**。例如公网 UDP 30116 → 本机 20116：

```sh
MODE=hy2 \
SERVER_IP=203.0.113.10 \
HY2_LISTEN_PORT=20116 \
HY2_SERVER_PORTS=30116 \
ENABLE_VPS_SHAPING=1 \
VPS_UPLOAD_MBIT=100 \
NODE_NAME='我的HY2' \
sh /tmp/install_reality.sh
```

单端口时两个端口号相同，手机直接连上 Hy2 监听端口，**没有转发动作，因此不需要 `local`**。只有一种例外：普通 VPS 上故意让手机连接端口与监听端口不同（例如手机连 30001、Hy2 监听 30000），才需要加 `HY2_PORT_HOPPING_MODE=local` 让脚本转发；否则更简单的做法是让两者相同。

### REALITY + HY2

普通 VPS：REALITY 用 TCP 20116，HY2 跳跃用 UDP 30000–30005，两套端口都要放行。

```sh
MODE=both \
SERVER_IP=203.0.113.10 \
ACTUAL_LISTEN_PORT=20116 \
LISTEN_PORT=20116 \
HY2_LISTEN_PORT=30000 \
HY2_SERVER_PORTS=30000-30005 \
HY2_PORT_HOPPING_MODE=local \
HY2_HOP_INTERVAL=30s \
ENABLE_VPS_SHAPING=1 \
VPS_UPLOAD_MBIT=100 \
NODE_NAME='我的节点' \
sh /tmp/install_reality.sh
```

商家 NAT：面板设置公网 TCP 30116 → 本机 20116，以及公网 UDP 30000–30005 → 本机同一 UDP 20116。

```sh
MODE=both \
SERVER_IP=203.0.113.10 \
ACTUAL_LISTEN_PORT=20116 \
LISTEN_PORT=30116 \
HY2_LISTEN_PORT=20116 \
HY2_SERVER_PORTS=30000-30005 \
HY2_PORT_HOPPING_MODE=external \
HY2_HOP_INTERVAL=30s \
ENABLE_VPS_SHAPING=1 \
VPS_UPLOAD_MBIT=100 \
NODE_NAME='我的节点' \
sh /tmp/install_reality.sh
```

TCP 和 UDP 可以使用相同端口号。`both` 的限速参数只作用于 HY2，不影响 REALITY。

## 参数说明

| 参数 | 填写 |
| --- | --- |
| `ACTUAL_LISTEN_PORT`、`LISTEN_PORT` | REALITY / SS 的本机端口、公网端口，各填一个数字 |
| `HY2_LISTEN_PORT` | HY2 实际监听的本机 UDP 端口，填一个数字 |
| `HY2_SERVER_PORTS` | 手机访问的公网 UDP 端口，单端口、范围或逗号列表 |
| `HY2_PORT_HOPPING_MODE` | 仅端口跳跃时可能需要：**普通公网 VPS** 填 `local`，由脚本建立本机转发；**商家 NAT 或直连**填 `external`（默认，可省略） |
| `HY2_HOP_INTERVAL` | 跳跃间隔，默认 `30s`，单端口时无意义 |
| `ENABLE_VPS_SHAPING` | 是否开启 HY2 限速：`1` 开启，`0` 关闭，不写则首次安装不限速、重装沿用原设置 |
| `VPS_UPLOAD_MBIT` | 开启限速时必填，HY2 发往客户端的**总**速率上限，单位 Mbps，所有客户端共享 |
| `NODE_NAME` | 节点名称，含空格时用引号包住 |

`HY2_SERVER_PORTS` 写法:

```sh
HY2_SERVER_PORTS=30000-30005          # 连续范围
HY2_SERVER_PORTS=30000,40006,50005    # 不连续端口，用英文逗号
HY2_SERVER_PORTS=30000-30005,40006    # 混合
```

范围也可以用 `30000:30005`，含义相同。只填商家允许的端口，避免与其他 UDP 服务重叠。

## HY2 限速

上面的 HY2 示例都开启了 100 Mbps 下载方向限速（BBR 不受影响），改 `VPS_UPLOAD_MBIT` 的数值即可。

- 首次不想限速：删除 `ENABLE_VPS_SHAPING=1` 和 `VPS_UPLOAD_MBIT=100` 两行。
- 已开启后重装：省略开关会沿用原设置；写 `ENABLE_VPS_SHAPING=0` 明确关闭。
- 不重装调速，不换凭据：

```sh
hy2-limit status        # 查看设置和规则状态
hy2-limit set 100       # 启用或改速为 100 Mbps，端口和跳跃设置不变
hy2-limit off           # 只关闭限速，本机跳跃转发保留
hy2-limit disable-all   # 关闭限速和本机跳跃；切到 reality / ss 前执行
```

## 安装后

```sh
cat /etc/sing-box/node_output.txt
```

也可以重新登录后执行 `shownode`。完整手机配置在 `/etc/sing-box/client.json`；`both` 模式另有 `client-reality.json`、`client-hy2.json`。这些文件包含密码，不要公开。

## 注意事项

- HY2 默认 Gecko 混淆，客户端不支持时在命令里加 `HY2_OBFS=salamander` 并用新配置。证书为自签并内嵌客户端，无需域名或 Cloudflare API。
- 网卡自动识别失败时按提示指定真实网卡，例如 `HY2_HOPPING_INTERFACE=ens3`（跳跃）或 `VPS_SHAPING_INTERFACE=ens3`（限速）；`ens3` 只是示例。
- 云安全组需自行放行；不要为安装删除已有网络规则或 SSH 端口映射。
- 修改跳跃范围或 `local`/`external` 前先断开客户端，等旧连接失效后再改，否则旧连接可能沿用旧转发；仅调速不受影响。
- 限速保护无法安全恢复时可能停止整个 sing-box，`both` 的 REALITY 也会停。新功能只经过模拟测试，尚未在真实 Linux VPS 验证连通性和吞吐，请先在可救援机器上测试。
