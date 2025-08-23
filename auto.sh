#!/bin/bash

# ============================================
#     Xray Argo 一键部署 + 自动订阅系统
#          支持保活和自动更新
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置文件路径
CONFIG_DIR="$HOME/.xray-manager"
NODE_INFO_FILE="$CONFIG_DIR/nodes_info"
CONFIG_FILE="$CONFIG_DIR/config"
XRAY_PID_FILE="$CONFIG_DIR/xray.pid"
SUBSCRIBE_PID_FILE="$CONFIG_DIR/subscribe.pid"
MONITOR_PID_FILE="$CONFIG_DIR/monitor.pid"
SUBSCRIBE_DIR="$CONFIG_DIR/subscribe"
PROJECT_DIR="python-xray-argo"

# 创建必要目录
mkdir -p "$CONFIG_DIR"
mkdir -p "$SUBSCRIBE_DIR"

# ============ 工具函数 ============
generate_uuid() {
    if command -v uuidgen &> /dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif command -v python3 &> /dev/null; then
        python3 -c "import uuid; print(str(uuid.uuid4()))"
    else
        hexdump -n 16 -e '4/4 "%08X" 1 "\n"' /dev/urandom | sed 's/$..$$..$$..$$..$$..$$..$$..$$..$$..$$..$$..$$..$$..$$..$$..$$..$/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/' | tr '[:upper:]' '[:lower:]'
    fi
}

get_public_ip() {
    curl -s ip.sb || curl -s ifconfig.me || curl -s icanhazip.com || echo "获取失败"
}

# ============ 订阅服务器 ============
create_subscribe_server() {
    cat > "$SUBSCRIBE_DIR/server.py" << 'EOFSUB'
#!/usr/bin/env python3
import json
import base64
import os
import time
import re
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

class SubscribeHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed_path = urlparse(self.path)
        
        if parsed_path.path == '/sub':
            self.send_subscription()
        elif parsed_path.path == '/clash':
            self.send_clash_config()
        elif parsed_path.path == '/status':
            self.send_status()
        else:
            self.send_404()
    
    def send_subscription(self):
        """发送V2Ray/Xray订阅"""
        try:
            nodes_file = os.path.join(os.path.dirname(__file__), 'nodes.json')
            with open(nodes_file, 'r') as f:
                nodes_data = json.load(f)
            
            links = []
            for node in nodes_data.get('nodes', []):
                if node.get('type') == 'vless' and node.get('active'):
                    link = f"vless://{node['uuid']}@{node['server']}:{node['port']}?"
                    link += f"encryption=none&security=tls&sni={node['sni']}"
                    link += f"&fp=randomized&type=ws&host={node['host']}"
                    link += f"&path={node['path']}#{node['name']}"
                    links.append(link)
            
            content = '\n'.join(links)
            encoded = base64.b64encode(content.encode()).decode()
            
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header('Subscription-Userinfo', 'upload=0; download=0; total=999999999999; expire=2099-12-31')
            self.end_headers()
            self.wfile.write(encoded.encode())
        except Exception as e:
            self.send_error(500, str(e))
    
    def send_clash_config(self):
        """发送Clash配置"""
        try:
            nodes_file = os.path.join(os.path.dirname(__file__), 'nodes.json')
            with open(nodes_file, 'r') as f:
                nodes_data = json.load(f)
            
            clash_config = {
                'port': 7890,
                'socks-port': 7891,
                'allow-lan': True,
                'mode': 'Rule',
                'log-level': 'info',
                'proxies': [],
                'proxy-groups': [
                    {
                        'name': '🚀 节点选择',
                        'type': 'select',
                        'proxies': ['♻️ 自动选择', 'DIRECT']
                    },
                    {
                        'name': '♻️ 自动选择',
                        'type': 'url-test',
                        'proxies': [],
                        'url': 'http://www.gstatic.com/generate_204',
                        'interval': 300
                    }
                ],
                'rules': [
                    'GEOIP,CN,DIRECT',
                    'MATCH,🚀 节点选择'
                ]
            }
            
            for node in nodes_data.get('nodes', []):
                if node.get('type') == 'vless' and node.get('active'):
                    proxy = {
                        'name': node['name'],
                        'type': 'vless',
                        'server': node['server'],
                        'port': node['port'],
                        'uuid': node['uuid'],
                        'udp': True,
                        'tls': True,
                        'network': 'ws',
                        'servername': node['sni'],
                        'ws-opts': {
                            'path': node['path'],
                            'headers': {'Host': node['host']}
                        }
                    }
                    clash_config['proxies'].append(proxy)
                    clash_config['proxy-groups'][0]['proxies'].insert(-1, node['name'])
                    clash_config['proxy-groups'][1]['proxies'].append(node['name'])
            
            import yaml
            content = yaml.dump(clash_config, allow_unicode=True, sort_keys=False)
            
            self.send_response(200)
            self.send_header('Content-Type', 'text/yaml; charset=utf-8')
            self.end_headers()
            self.wfile.write(content.encode())
        except ImportError:
            self.send_error(500, "Please install pyyaml: pip3 install pyyaml")
        except Exception as e:
            self.send_error(500, str(e))
    
    def send_status(self):
        """发送节点状态"""
        try:
            nodes_file = os.path.join(os.path.dirname(__file__), 'nodes.json')
            with open(nodes_file, 'r') as f:
                nodes_data = json.load(f)
            
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(nodes_data, indent=2).encode())
        except Exception as e:
            self.send_error(500, str(e))
    
    def send_404(self):
        self.send_error(404, "Not Found")
    
    def log_message(self, format, *args):
        print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {format%args}")

class NodeUpdater(threading.Thread):
    """节点自动更新线程"""
    def __init__(self, interval=30):
        super().__init__()
        self.interval = interval
        self.daemon = True
        self.running = True
    
    def run(self):
        while self.running:
            self.update_nodes()
            time.sleep(self.interval)
    
    def update_nodes(self):
        """更新节点信息"""
        try:
            config_file = os.path.expanduser('~/.xray-manager/config')
            nodes_file = os.path.join(os.path.dirname(__file__), 'nodes.json')
            
            if not os.path.exists(config_file):
                return
            
            # 读取配置
            config = {}
            with open(config_file, 'r') as f:
                for line in f:
                    if '=' in line:
                        key, value = line.strip().split('=', 1)
                        config[key] = value
            
            # 检查Xray日志获取最新域名
            log_file = '/tmp/xray-argo.log'
            current_domain = config.get('ARGO_DOMAIN', '')
            new_domain = current_domain
            
            if os.path.exists(log_file):
                with open(log_file, 'r') as f:
                    content = f.read()
                    matches = re.findall(r'https://([a-zA-Z0-9.-]+\.trycloudflare\.com)', content)
                    if matches:
                        new_domain = matches[-1]  # 使用最新的域名
            
            # 更新节点信息
            nodes_data = {
                'update_time': time.strftime('%Y-%m-%d %H:%M:%S'),
                'nodes': [{
                    'type': 'vless',
                    'name': f"Argo-Auto",
                    'server': config.get('CFIP', 'joeyblog.net'),
                    'port': 443,
                    'uuid': config.get('UUID', ''),
                    'sni': new_domain,
                    'host': new_domain,
                    'path': '/?ed=2560',
                    'active': True,
                    'domain_changed': (new_domain != current_domain)
                }]
            }
            
            # 保存节点信息
            with open(nodes_file, 'w') as f:
                json.dump(nodes_data, f, indent=2)
            
            # 如果域名变化，更新配置文件
            if new_domain != current_domain and new_domain:
                config['ARGO_DOMAIN'] = new_domain
                with open(config_file, 'w') as f:
                    for key, value in config.items():
                        f.write(f"{key}={value}\n")
                print(f"[更新] 域名已变更: {current_domain} -> {new_domain}")
            
        except Exception as e:
            print(f"[错误] 更新失败: {e}")

if __name__ == '__main__':
    # 安装依赖
    try:
        import yaml
    except ImportError:
        print("Installing pyyaml...")
        os.system('pip3 install pyyaml')
    
    # 初始化节点文件
    nodes_file = os.path.join(os.path.dirname(__file__), 'nodes.json')
    if not os.path.exists(nodes_file):
        with open(nodes_file, 'w') as f:
            json.dump({'update_time': '', 'nodes': []}, f)
    
    # 启动更新线程
    updater = NodeUpdater(interval=30)
    updater.start()
    
    # 启动HTTP服务器
    port = int(os.environ.get('SUBSCRIBE_PORT', 8888))
    server = HTTPServer(('0.0.0.0', port), SubscribeHandler)
    print(f"订阅服务器启动: http://0.0.0.0:{port}")
    server.serve_forever()
EOFSUB
    
    chmod +x "$SUBSCRIBE_DIR/server.py"
}

# ============ 保活监控脚本 ============
create_monitor_script() {
    cat > "$CONFIG_DIR/monitor.sh" << 'EOFMON'
#!/bin/bash

CONFIG_DIR="$HOME/.xray-manager"
XRAY_PID_FILE="$CONFIG_DIR/xray.pid"
SUBSCRIBE_PID_FILE="$CONFIG_DIR/subscribe.pid"
CONFIG_FILE="$CONFIG_DIR/config"
LOG_FILE="$CONFIG_DIR/monitor.log"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] \$1" >> "$LOG_FILE"
}

check_and_restart_xray() {
    if [ -f "$XRAY_PID_FILE" ]; then
        XRAY_PID=$(cat "$XRAY_PID_FILE")
        if ! ps -p $XRAY_PID > /dev/null 2>&1; then
            log_message "Xray进程已停止，正在重启..."
            
            # 读取配置
            source "$CONFIG_FILE"
            
            # 重启Xray
            cd ~/python-xray-argo
            nohup python3 app.py > /tmp/xray-argo.log 2>&1 &
            NEW_PID=$!
            echo $NEW_PID > "$XRAY_PID_FILE"
            
            log_message "Xray已重启，新PID: $NEW_PID"
            
            # 等待获取新域名
            sleep 10
        fi
    fi
}

check_and_restart_subscribe() {
    if [ -f "$SUBSCRIBE_PID_FILE" ]; then
        SUB_PID=$(cat "$SUBSCRIBE_PID_FILE")
        if ! ps -p $SUB_PID > /dev/null 2>&1; then
            log_message "订阅服务已停止，正在重启..."
            
            cd "$CONFIG_DIR/subscribe"
            export SUBSCRIBE_PORT="8888"
            nohup python3 server.py > subscribe.log 2>&1 &
            NEW_PID=$!
            echo $NEW_PID > "$SUBSCRIBE_PID_FILE"
            
            log_message "订阅服务已重启，新PID: $NEW_PID"
        fi
    fi
}

# 主循环
while true; do
    check_and_restart_xray
    check_and_restart_subscribe
    sleep 30
done
EOFMON
    
    chmod +x "$CONFIG_DIR/monitor.sh"
}

# ============ 主要功能函数 ============
install_dependencies() {
    echo -e "${BLUE}检查并安装依赖...${NC}"
    
    # Python3
    if ! command -v python3 &> /dev/null; then
        echo -e "${YELLOW}正在安装 Python3...${NC}"
        sudo apt-get update && sudo apt-get install -y python3 python3-pip
    fi
    
    # Python依赖
    if ! python3 -c "import requests" &> /dev/null; then
        echo -e "${YELLOW}正在安装 requests...${NC}"
        pip3 install requests
    fi
    
    if ! python3 -c "import yaml" &> /dev/null; then
        echo -e "${YELLOW}正在安装 pyyaml...${NC}"
        pip3 install pyyaml
    fi
    
    echo -e "${GREEN}依赖检查完成！${NC}"
}

download_xray_project() {
    if [ ! -d "$PROJECT_DIR" ]; then
        echo -e "${BLUE}下载 Xray Argo 项目...${NC}"
        if command -v git &> /dev/null; then
            git clone https://github.com/eooce/python-xray-argo.git
        else
            wget -q https://github.com/eooce/python-xray-argo/archive/refs/heads/main.zip -O xray.zip
            unzip -q xray.zip
            mv python-xray-argo-main python-xray-argo
            rm xray.zip
        fi
    fi
}

quick_deploy() {
    echo -e "${CYAN}========== 极速部署模式 ==========${NC}"
    echo
    
    # 安装依赖
    install_dependencies
    
    # 下载项目
    download_xray_project
    
    cd "$PROJECT_DIR"
    
    # 生成UUID
    UUID_INPUT=$(generate_uuid)
    echo -e "${GREEN}生成UUID: $UUID_INPUT${NC}"
    
    # 配置参数
    CFIP="joeyblog.net"
    PORT="3000"
    
    # 修改配置
    cp app.py app.py.backup 2>/dev/null
    sed -i "s/UUID = os.environ.get('UUID', '[^']*')/UUID = os.environ.get('UUID', '$UUID_INPUT')/" app.py
    sed -i "s/CFIP = os.environ.get('CFIP', '[^']*')/CFIP = os.environ.get('CFIP', '$CFIP')/" app.py
    sed -i "s/PORT = int(os.environ.get('PORT', [^)]*)/PORT = int(os.environ.get('PORT', $PORT)/" app.py
    
    # 启动Xray服务
    echo -e "${BLUE}启动 Xray 服务...${NC}"
    nohup python3 app.py > /tmp/xray-argo.log 2>&1 &
    XRAY_PID=$!
    echo $XRAY_PID > "$XRAY_PID_FILE"
    
    # 等待获取域名
    echo -e "${YELLOW}等待获取Argo域名...${NC}"
    sleep 8
    
    # 获取域名
    ARGO_DOMAIN=$(grep -oP 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' /tmp/xray-argo.log | head -1 | sed 's|https://||')
    
    if [ -z "$ARGO_DOMAIN" ]; then
        sleep 5
        ARGO_DOMAIN=$(grep -oP 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' /tmp/xray-argo.log | head -1 | sed 's|https://||')
    fi
    
    # 保存配置
    cat > "$CONFIG_FILE" << EOF
UUID=$UUID_INPUT
CFIP=$CFIP
PORT=$PORT
ARGO_DOMAIN=$ARGO_DOMAIN
DEPLOY_TIME=$(date '+%Y-%m-%d %H:%M:%S')
EOF
    
    # 创建订阅服务器
    echo -e "${BLUE}部署订阅服务器...${NC}"
    create_subscribe_server
    
    # 启动订阅服务
    cd "$SUBSCRIBE_DIR"
    export SUBSCRIBE_PORT="8888"
    nohup python3 server.py > subscribe.log 2>&1 &
    SUB_PID=$!
    echo $SUB_PID > "$SUBSCRIBE_PID_FILE"
    
    sleep 2
    
    # 创建并启动监控脚本
    echo -e "${BLUE}启动保活监控...${NC}"
    create_monitor_script
    nohup bash "$CONFIG_DIR/monitor.sh" > /dev/null 2>&1 &
    MON_PID=$!
    echo $MON_PID > "$MONITOR_PID_FILE"
    
    # 获取公网IP
    PUBLIC_IP=$(get_public_ip)
    
    # 输出结果
    echo
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}        🎉 部署成功！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo
    echo -e "${CYAN}【订阅地址】（永久固定）${NC}"
    echo -e "${YELLOW}V2Ray/Xray订阅:${NC}"
    echo -e "${GREEN}http://${PUBLIC_IP}:8888/sub${NC}"
    echo
    echo -e "${YELLOW}Clash订阅:${NC}"
    echo -e "${GREEN}http://${PUBLIC_IP}:8888/clash${NC}"
    echo
    echo -e "${CYAN}【节点信息】${NC}"
    echo -e "UUID: ${YELLOW}$UUID_INPUT${NC}"
    echo -e "优选IP: ${YELLOW}$CFIP${NC}"
    echo -e "Argo域名: ${YELLOW}${ARGO_DOMAIN:-获取中...}${NC}"
    echo
    echo -e "${CYAN}【系统特性】${NC}"
    echo -e "✅ 订阅地址永久不变"
    echo -e "✅ 节点自动更新（30秒检测）"
    echo -e "✅ 服务自动保活"
    echo -e "✅ 域名变化自动同步"
    echo
    echo -e "${CYAN}【管理命令】${NC}"
    echo -e "查看状态: ${YELLOW}bash \$0 status${NC}"
    echo -e "查看日志: ${YELLOW}bash \$0 logs${NC}"
    echo -e "重启服务: ${YELLOW}bash \$0 restart${NC}"
    echo -e "停止服务: ${YELLOW}bash \$0 stop${NC}"
    echo
    
    # 保存信息文件
    cat > "$NODE_INFO_FILE" << EOF
========================================
          部署信息记录
========================================
部署时间: $(date '+%Y-%m-%d %H:%M:%S')
----------------------------------------
【订阅地址】
V2Ray订阅: http://${PUBLIC_IP}:8888/sub
Clash订阅: http://${PUBLIC_IP}:8888/clash
状态查询: http://${PUBLIC_IP}:8888/status
----------------------------------------
【节点配置】
UUID: $UUID_INPUT
优选IP: $CFIP
端口: $PORT
当前域名: $ARGO_DOMAIN
----------------------------------------
【进程信息】
Xray PID: $XRAY_PID
订阅服务 PID: $SUB_PID
监控服务 PID: $MON_PID
========================================
EOF
}

# ============ 管理功能 ============
show_status() {
    echo -e "${CYAN}========== 服务状态 ==========${NC}"
    echo
    
    # Xray状态
    if [ -f "$XRAY_PID_FILE" ]; then
        PID=$(cat "$XRAY_PID_FILE")
        if ps -p $PID > /dev/null 2>&1; then
            echo -e "Xray服务: ${GREEN}运行中${NC} (PID: $PID)"
        else
            echo -e "Xray服务: ${RED}已停止${NC}"
        fi
    else
        echo -e "Xray服务: ${YELLOW}未部署${NC}"
    fi
    
    # 订阅服务状态
    if [ -f "$SUBSCRIBE_PID_FILE" ]; then
        PID=$(cat "$SUBSCRIBE_PID_FILE")
        if ps -p $PID > /dev/null 2>&1; then
            echo -e "订阅服务: ${GREEN}运行中${NC} (PID: $PID)"
        else
            echo -e "订阅服务: ${RED}已停止${NC}"
        fi
    else
        echo -e "订阅服务: ${YELLOW}未部署${NC}"
    fi
    
    # 监控服务状态
    if [ -f "$MONITOR_PID_FILE" ]; then
        PID=$(cat "$MONITOR_PID_FILE")
        if ps -p $PID > /dev/null 2>&1; then
            echo -e "监控服务: ${GREEN}运行中${NC} (PID: $PID)"
        else
            echo -e "监控服务: ${RED}已停止${NC}"
        fi
    else
        echo -e "监控服务: ${YELLOW}未部署${NC}"
    fi
    
    echo
    
    # 显示配置信息
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${CYAN}当前配置:${NC}"
        cat "$CONFIG_FILE" | while read line; do
            echo "  $line"
        done
    fi
    
    echo
}

show_logs() {
    echo -e "${CYAN}选择要查看的日志:${NC}"
    echo "1) Xray日志"
    echo "2) 订阅服务日志"
    echo "3) 监控日志"
    read -p "请选择 (1-3): " choice
    
    case $choice in
        1) tail -f /tmp/xray-argo.log ;;
        2) tail -f "$SUBSCRIBE_DIR/subscribe.log" ;;
        3) tail -f "$CONFIG_DIR/monitor.log" ;;
        *) echo -e "${RED}无效选择${NC}" ;;
    esac
}

restart_all() {
    echo -e "${YELLOW}重启所有服务...${NC}"
    
    # 停止所有服务
    [ -f "$XRAY_PID_FILE" ] && kill $(cat "$XRAY_PID_FILE") 2>/dev/null
    [ -f "$SUBSCRIBE_PID_FILE" ] && kill $(cat "$SUBSCRIBE_PID_FILE") 2>/dev/null
    [ -f "$MONITOR_PID_FILE" ] && kill $(cat "$MONITOR_PID_FILE") 2>/dev/null
    
    sleep 2
    
    # 重新启动
    source "$CONFIG_FILE"
    
    # 启动Xray
    cd ~/python-xray-argo
    nohup python3 app.py > /tmp/xray-argo.log 2>&1 &
    echo $! > "$XRAY_PID_FILE"
    
    # 启动订阅服务
    cd "$SUBSCRIBE_DIR"
    export SUBSCRIBE_PORT="8888"
    nohup python3 server.py > subscribe.log 2>&1 &
    echo $! > "$SUBSCRIBE_PID_FILE"
    
    # 启动监控
    nohup bash "$CONFIG_DIR/monitor.sh" > /dev/null 2>&1 &
    echo $! > "$MONITOR_PID_FILE"
    
    echo -e "${GREEN}所有服务已重启${NC}"
}

stop_all() {
    echo -e "${YELLOW}停止所有服务...${NC}"
    
    [ -f "$XRAY_PID_FILE" ] && kill $(cat "$XRAY_PID_FILE") 2>/dev/null && rm -f "$XRAY_PID_FILE"
    [ -f "$SUBSCRIBE_PID_FILE" ] && kill $(cat "$SUBSCRIBE_PID_FILE") 2>/dev/null && rm -f "$SUBSCRIBE_PID_FILE"
    [ -f "$MONITOR_PID_FILE" ] && kill $(cat "$MONITOR_PID_FILE") 2>/dev/null && rm -f "$MONITOR_PID_FILE"
    
    echo -e "${GREEN}所有服务已停止${NC}"
}

# ============ 主程序 ============
case "\$1" in
    status)
        show_status
        ;;
    logs)
        show_logs
        ;;
    restart)
        restart_all
        ;;
    stop)
        stop_all
        ;;
    *)
        clear
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}    Xray Argo 智能订阅系统 v2.0${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo
        echo -e "${CYAN}特性说明:${NC}"
        echo -e "• 一键部署，极速配置"
        echo -e "• 固定订阅地址，永不改变"
        echo -e "• 自动检测域名变化并更新"
        echo -e "• 服务保活，自动重启"
        echo -e "• 支持V2Ray/Clash多种格式"
        echo
        echo -e "${YELLOW}是否开始极速部署? (y/n)${NC}"
        read -p "> " confirm
        
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            quick_deploy
        else
            echo -e "${BLUE}已取消部署${NC}"
            echo
            echo -e "${CYAN}管理命令:${NC}"
            echo -e "查看状态: bash \$0 status"
            echo -e "查看日志: bash \$0 logs"
            echo -e "重启服务: bash \$0 restart"
            echo -e "停止服务: bash \$0 stop"
        fi
        ;;
esac
