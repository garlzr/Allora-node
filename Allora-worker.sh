#!/bin/bash
# 检查是否以root用户运行脚本
if [ "$(id -u)" != "0" ]; then
    echo "此脚本需要以root用户权限运行。"
    echo "请尝试使用 'sudo -i' 命令切换到root用户，然后再次运行此脚本。"
    sudo su
fi

# 脚本保存路径
SCRIPT_PATH="$HOME/Allora-worker.sh"

function check_port(){

    if ! command -v netstat &> /dev/null; then
    sudo apt-get update
    sudo apt-get install net-tools
    fi

    ports=(1317 9090 26657 26658 6060 26656 26660)

    conflict=false

    for port in "${ports[@]}"
    do
        count=$(netstat -tuln | grep ":$port " | wc -l)
        if [ $count -gt 1 ]; then
            echo "端口 $port 存在冲突:"
            netstat -tuln | grep ":$port "
            conflict=true
        fi
    done

    if [ "$conflict" = false ]; then
        echo "端口未冲突，请开始安装工人节点"
    fi
}

function install_node() {
  # Update and install required packages
  sudo apt update && sudo apt upgrade -y

  sudo apt install -y ca-certificates zlib1g-dev libncurses5-dev libgdbm-dev libnss3-dev curl git wget make jq build-essential pkg-config lsb-release libssl-dev libreadline-dev libffi-dev gcc screen unzip lz4
  
  # Install Python
  dpkg -s python3 &>/dev/null || sudo apt install -y python3
  dpkg -s python3-pip &>/dev/null || sudo apt install -y python3-pip

  # Install Docker
  if ! command -v docker &>/dev/null; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io
    sudo groupadd docker || true
    sudo usermod -aG docker $USER
  fi

  # Install Docker Compose
  if ! command -v docker-compose &>/dev/null; then
    VER=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f 4)
    curl -L "https://github.com/docker/compose/releases/download/${VER}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
  fi


  sudo rm -rf /usr/local/go
  curl -L https://go.dev/dl/go1.22.4.linux-amd64.tar.gz | sudo tar -xzf - -C /usr/local
  echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> $HOME/.bash_profile
  echo 'export PATH=$PATH:$(go env GOPATH)/bin' >> $HOME/.bash_profile
  source $HOME/.bash_profile

  # Clone and build Allora chain
  git clone https://github.com/allora-network/allora-chain.git $HOME/allora-chain
  cd $HOME/allora-chain && make all


  # Wallet setup
  echo "Choose an option: "
  echo "1. 使用已有钱包(24位助记词)"
  echo "2. 生成新钱包【建议用脚本生成的钱包 请记录助记词和地址】"
  read -p "请输入你的选择: " option
    
  if [ "$option" == "1" ]; then
      read -p "Enter your seed phrases: " seed_phrase
      allorad keys add testkey --recover <<< "$seed_phrase"
  else
      allorad keys add testkey
  fi

  # Clone and set up the prediction node
  sleep 20
  cd $HOME
  git clone https://github.com/allora-network/basic-coin-prediction-node
  cd basic-coin-prediction-node
  mkdir worker-data head-data
  sudo chmod -R 777 worker-data head-data

  sudo docker run -it --entrypoint=bash -v $(pwd)/head-data:/data alloranetwork/allora-inference-base:latest -c "mkdir -p /data/keys && (cd /data/keys && allora-keys)"
  sudo docker run -it --entrypoint=bash -v $(pwd)/worker-data:/data alloranetwork/allora-inference-base:latest -c "mkdir -p /data/keys && (cd /data/keys && allora-keys)"

  echo "Your head-id is: "
  cat head-data/keys/identity
  echo

  read -p "Re-enter your head-id(复制上方head-id): " head_id
  read -p "Enter your wallet seed phrases(填写24位钱包助记词): " wallet_seed

  cat <<EOF > docker-compose.yml
  version: '3'
  services:
    inference:
      container_name: inference-basic-eth-pred
      build:
        context: .
      command: python -u /app/app.py
      ports:
        - "8000:8000"
      networks:
        eth-model-local:
          aliases:
            - inference
          ipv4_address: 172.22.0.4
      healthcheck:
        test: ["CMD", "curl", "-f", "http://localhost:8000/inference/ETH"]
        interval: 10s
        timeout: 10s
        retries: 12
      volumes:
        - ./inference-data:/app/data

    updater:
      container_name: updater-basic-eth-pred
      build: .
      environment:
        - INFERENCE_API_ADDRESS=http://inference:8000
      command: >
        sh -c "
        while true; do
          python -u /app/update_app.py;
          sleep 24h;
        done
        "
      depends_on:
        inference:
          condition: service_healthy
      networks:
        eth-model-local:
          aliases:
            - updater
          ipv4_address: 172.22.0.5

    worker:
      container_name: worker-basic-eth-pred
      environment:
        - INFERENCE_API_ADDRESS=http://inference:8000
        - HOME=/data
      build:
        context: .
        dockerfile: Dockerfile_b7s
      entrypoint:
        - "/bin/bash"
        - "-c"
        - |
          if [ ! -f /data/keys/priv.bin ]; then
            echo "Generating new private keys..."
            mkdir -p /data/keys
            cd /data/keys
            allora-keys
          fi
          allora-node --role=worker --peer-db=/data/peerdb --function-db=/data/function-db \
            --runtime-path=/app/runtime --runtime-cli=bls-runtime --workspace=/data/workspace \
            --private-key=/data/keys/priv.bin --log-level=debug --port=9011 \
            --boot-nodes=/ip4/172.22.0.100/tcp/9010/p2p/$head_id \
            --topic=allora-topic-1-worker \
            --allora-chain-key-name=testkey \
            --allora-chain-restore-mnemonic='$wallet_seed' \
            --allora-node-rpc-address=https://allora-rpc.edgenet.allora.network/ \
            --allora-chain-topic-id=1
      volumes:
        - ./worker-data:/data
      working_dir: /data
      depends_on:
        - inference
        - head
      networks:
        eth-model-local:
          aliases:
            - worker
          ipv4_address: 172.22.0.10

    head:
      container_name: head-basic-eth-pred
      image: alloranetwork/allora-inference-base-head:latest
      environment:
        - HOME=/data
      entrypoint:
        - "/bin/bash"
        - "-c"
        - |
          if [ ! -f /data/keys/priv.bin ]; then
            echo "Generating new private keys..."
            mkdir -p /data/keys
            cd /data/keys
            allora-keys
          fi
          allora-node --role=head --peer-db=/data/peerdb --function-db=/data/function-db  \
            --runtime-path=/app/runtime --runtime-cli=bls-runtime --workspace=/data/workspace \
            --private-key=/data/keys/priv.bin --log-level=debug --port=9010 --rest-api=:6000
      ports:
        - "6000:6000"
      volumes:
        - ./head-data:/data
      working_dir: /data
      networks:
        eth-model-local:
          aliases:
            - head
          ipv4_address: 172.22.0.100

  networks:
    eth-model-local:
      driver: bridge
      ipam:
        config:
          - subnet: 172.22.0.0/24

  volumes:
    inference-data:
    worker-data:
    head-data:
EOF

  docker-compose up --restart=always --build
  docker-compose up -d
  docker update --restart=always worker-basic-eth-pred && docker update --restart=always updater-basic-eth-pred && docker update --restart=always inference-basic-eth-pred && docker update --restart=always head-basic-eth-pred
  docker-compose logs -f --tail 20
}

function check_service_status() {
  cd $HOME/basic-coin-prediction-node
  docker-compose logs -f --tail 20
}

function restart() {
  cd $HOME/basic-coin-prediction-node
  docker-compose down
  docker-compose up -d
  docker-compose logs -f --tail 20
}

function uninstall(){
   # 定义需要删除的镜像列表
    images=(
        "basic-coin-prediction-node_worker"
        "basic-coin-prediction-node_updater"
        "basic-coin-prediction-node_inference"
        "alloranetwork/allora-inference-base-head:latest"
        "alloranetwork/allora-inference-base:latest"
    )

    # 停止并删除相应的容器
    for image in "${images[@]}"; do
        # 获取运行该镜像的所有容器ID
        container_ids=$(docker ps -a -q --filter ancestor=$image)
        
        # 停止并删除容器
        if [ -n "$container_ids" ]; then
            docker stop $container_ids 2>/dev/null
            docker rm $container_ids 2>/dev/null
        fi
    done

    # 删除镜像
    for image in "${images[@]}"; do
        docker rmi $image 2>/dev/null
    done

    # 删除相关文件和目录
    rm -rf $HOME/basic-coin-prediction-node $HOME/allora-chain $HOME/.allorad

    echo "节点卸载完成······"
}

function backup(){

    source_file="$HOME/basic-coin-prediction-node/docker-compose.yml"
    target_folder="$HOME/allora_key"

    # 检查目标文件夹是否存在，不存在则创建
    if [ ! -d "$target_folder" ]; then
        mkdir -p "$target_folder"
    fi

    # 备份文件到目标文件夹
    cp "$source_file" "$target_folder"

    echo "已备份到目标文件夹 $target_folder 中(节点的助记词在文件中)"

}

function status(){
      curl --location 'http://localhost:6000/api/v1/functions/execute' \
    --header 'Content-Type: application/json' \
    --data '{
        "function_id": "bafybeigpiwl3o73zvvl6dxdqu7zqcub5mhg65jiky2xqb4rdhfmikswzqm",
        "method": "allora-inference-function.wasm",
        "parameters": null,
        "topic": "1",
        "config": {
            "env_vars": [
                {
                    "name": "BLS_REQUEST_PATH",
                    "value": "/api"
                },
                {
                    "name": "ALLORA_ARG_PARAMS",
                    "value": "ETH"
                }
            ],
            "number_of_nodes": -1,
            "timeout": 2
        }
    }'
}

function wallet(){
    allorad keys list
}

function add(){
    allorad keys add testkey --recover
}

# 主菜单
function main_menu() {
    clear
    echo "领水网站 https://faucet.edgenet.allora.network/"
    echo "安装完成后请前往Allora Points 仪表板中登录Keplr钱包账户 https://app.allora.network/points/overview"
    echo "在安装节点过程中，生成新钱包后请记录地址和助记词----前往领水----保证后续安装过程中，第二次填写助记词时钱包有水"
    echo "请选择要执行的操作:"
    echo "1. 安装节点(先执行6查询 如果冲突了需要单独处理)"
    echo "2. 查看节点日志"
    echo "3. 重启节点"
    echo "4. 备份节点钱包数据"
    echo "5. 卸载节点"
    echo "6. 端口冲突检查(安装前请执行)"
    echo "7. 节点运行情况查询({"code":"200","request_id":xxxxxxxxxxx}即为运行正常)"
    echo "8. 钱包查询"
    echo "9. 导入钱包"
    read -p "请输入选项（1-9）: " OPTION

    case $OPTION in
    1) install_node ;;
    2) check_service_status ;;
    3) restart ;;
    4) backup ;;
    5) uninstall ;;
    6) check_port ;;
    7) status ;;
    8) wallet ;;
    9) add ;;
    *)
        echo "无效选项。"
        read -p "按任意键返回主菜单..."
        main_menu
        ;;
    esac
}

# 显示主菜单
main_menu
