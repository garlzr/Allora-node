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

    ports=(1317 9090 26657 26658 6060 26656 26660)

    for port in "${ports[@]}"
    do
        count=$(netstat -tuln | grep ":$port " | wc -l)
        if [ $count -gt 1 ]; then
            echo "端口 $port 存在冲突:"
            netstat -tuln | grep ":$port "
        fi
    done
}

function install_node() {
  # Update and install required packages
  sudo apt update && sudo apt upgrade -y

  # Check and install required packages
  packages=(ca-certificates zlib1g-dev libncurses5-dev libgdbm-dev libnss3-dev curl git wget make jq build-essential pkg-config lsb-release libssl-dev libreadline-dev libffi-dev gcc screen unzip lz4)
  for package in "${packages[@]}"; do
    dpkg -s $package &>/dev/null || sudo apt install -y $package
  done

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

  # Install Go
  if ! command -v go &>/dev/null; then
    sudo rm -rf /usr/local/go
    curl -L https://go.dev/dl/go1.22.4.linux-amd64.tar.gz | sudo tar -xzf - -C /usr/local
    echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> $HOME/.bash_profile
    echo 'export PATH=$PATH:$(go env GOPATH)/bin' >> $HOME/.bash_profile
    source $HOME/.bash_profile
  fi

  # Clone and build Allora chain
  git clone https://github.com/allora-network/allora-chain.git $HOME/allora-chain
  cd $HOME/allora-chain && make all


  # Wallet setup
  echo "Choose an option: "
  echo "1. Use existing wallet"
  echo "2. Create new wallet"
  read -p "Enter option number: " option

  if [ "$option" == "1" ]; then
      read -p "Enter your seed phrases: " seed_phrase
      allorad keys add testkey --recover <<< "$seed_phrase"
  else
      allorad keys add testkey
  fi

  # Clone and set up the prediction node
  cd $HOME
  git clone https://github.com/allora-network/basic-coin-prediction-node
  cd basic-coin-prediction-node
  mkdir -p worker-data head-data
  sudo chmod -R 777 worker-data head-data

  sudo docker run -it --entrypoint=bash -v $(pwd)/head-data:/data alloranetwork/allora-inference-base:latest -c "mkdir -p /data/keys && (cd /data/keys && allora-keys)"
  sudo docker run -it --entrypoint=bash -v $(pwd)/worker-data:/data alloranetwork/allora-inference-base:latest -c "mkdir -p /data/keys && (cd /data/keys && allora-keys)"

  echo "Your head-id is: "
  cat head-data/keys/identity
  echo

  read -p "Re-enter your head-id: " head_id
  read -p "Enter your wallet seed phrases: " wallet_seed

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
        timeout: 5s
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

  docker-compose build
  docker-compose up -d
  docker-compose logs -f
}

function check_service_status(){
  cd $HOME/basic-coin-prediction-node
  docker-compose logs -f
}

function restart(){
  cd $HOME/basic-coin-prediction-node
  docker-compose down
  docker-compose up -d
  docker-compose logs -f
  docker-compose logs -f
}

function uninstall(){
  rm -rf $HOME/basic-coin-prediction-node
  echo "节点卸载完成······"
}

function backup(){
  2

}
# 主菜单
function main_menu() {
    clear
    echo "请选择要执行的操作:"
    echo "1. 安装节点"
    echo "2. 查看节点日志"
    echo "3. 重启节点"
    echo "4. 备份节点钱包数据"
    echo "5. 卸载节点"
    echo "6. 端口冲突检查(安装前请执行)"
    read -p "请输入选项（1-5）: " OPTION

    case $OPTION in
    1) install_node ;;
    2) check_service_status ;;
    3) restart ;;
    4) backup ;;
    5) uninstall ;;
    6) check_port ;;
    *)
        echo "无效选项。"
        read -p "按任意键返回主菜单..."
        main_menu
        ;;
    esac
}

# 显示主菜单
main_menu
