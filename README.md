```
wget -qO- https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh | LISTEN_PORT=x SERVER_IP=y sh
```
## 一、替换参数 x y
- nat机器需要把`LISTEN_PORT=x`中的`x`换成映射后的端口
- 非nat或ipv6 only的机器把`x`换成`0`，端口会自动设置为443
- `SERVER_IP=y`需要用 公网ip 替换掉`y`

## 二、快捷键
- 输入`shownode`展示节点（需要重新登录才能生效）
