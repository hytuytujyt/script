curl -fsSL https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh | LISTEN_PORT=x SERVER_IP=y bash

如果是alpine，需要先apk update && apk add curl bash

如果是nat机器需要把LISTEN_PORT=x中的x换成映射后的端口

SERVER_IP=y需要用公网ip替换掉y

输入shownode展示节点（需要重新登录才能生效）
