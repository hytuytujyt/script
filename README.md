curl -fsSL https://raw.githubusercontent.com/hytuytujyt/script/main/install_reality.sh | LISTEN_PORT=x SERVER_IP=y bash

alpine没有bash和curl，需要先apk update && apk add curl bash：ubuntu/debian只有bash没有curl，需要apt update && apt install curl -y

如果是nat机器需要把LISTEN_PORT=x中的x换成映射后的端口,非nat或ipv6 only的机器把x换成0，端口会自动设置为443

SERVER_IP=y需要用公网ip替换掉y

输入shownode展示节点（需要重新登录才能生效）
