#!/bin/bash
# WiFi热点自动切换脚本
# 优先连接已知WiFi，无可用WiFi时开启热点模式

set -e

# 配置参数
HOTSPOT_SSID="RasPi-DataCollector"
HOTSPOT_PASSWORD="raspberry2024"
HOTSPOT_INTERFACE="wlan0"
CHECK_INTERVAL=30  # 检查间隔（秒）
LOG_FILE="/home/pi/data/logs/wifi_hotspot.log"

# 确保日志目录存在
mkdir -p "$(dirname "$LOG_FILE")"

# 日志函数
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# 检查网络连接
check_internet() {
    ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1
    return $?
}

# 检查是否有可用的已知WiFi (Ubuntu 24.04适配)
check_known_wifi() {
    # 使用nmcli扫描可用WiFi网络
    local available_networks=$(nmcli -t -f SSID dev wifi list 2>/dev/null | grep -v "^$" | sort -u)
    
    # 获取已保存的WiFi连接
    local known_networks=$(nmcli -t -f NAME connection show --active 2>/dev/null | grep -v "^$")
    local saved_networks=$(nmcli -t -f NAME connection show 2>/dev/null | grep -v "^$")
    
    # 合并已知网络
    local all_known="$known_networks $saved_networks"
    
    # 查找匹配的网络
    for known in $all_known; do
        for available in $available_networks; do
            if [ "$known" = "$available" ]; then
                echo "$known"
                return 0
            fi
        done
    done
    
    return 1
}

# 连接到WiFi网络 (Ubuntu 24.04适配)
connect_to_wifi() {
    local ssid="$1"
    log_message "尝试连接到WiFi网络: $ssid"
    
    # 停止热点服务
    stop_hotspot
    
    # 使用nmcli device wifi connect命令连接WiFi
    if nmcli device wifi connect "$ssid" 2>/dev/null; then
        log_message "成功连接WiFi: $ssid"
    else
        log_message "尝试重新扫描并连接WiFi: $ssid"
        nmcli device wifi rescan
        sleep 5
        nmcli device wifi connect "$ssid" 2>/dev/null || {
            log_message "连接WiFi失败: $ssid"
            return 1
        }
    fi
    
    # 等待网络稳定
    sleep 10
    
    # 验证网络连接
    if check_internet; then
        local ip_addr=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' || echo "未知")
        log_message "网络连接正常，IP地址: $ip_addr"
        return 0
    else
        log_message "WiFi已连接但无法访问互联网"
        return 1
    fi
}

# 启动热点模式 (Ubuntu 24.04适配)
start_hotspot() {
    log_message "启动热点模式..."
    
    # 停止可能的WiFi连接
    nmcli device disconnect "$HOTSPOT_INTERFACE" 2>/dev/null || true
    
    # 删除现有的热点连接配置（如果存在）
    nmcli connection delete "$HOTSPOT_SSID" 2>/dev/null || true
    
    # 创建热点连接
    nmcli connection add type wifi ifname "$HOTSPOT_INTERFACE" \
        con-name "$HOTSPOT_SSID" \
        autoconnect yes \
        wifi.mode ap \
        wifi.ssid "$HOTSPOT_SSID" \
        ipv4.method shared \
        ipv4.addresses 192.168.4.1/24
    
    # 设置WiFi安全
    nmcli connection modify "$HOTSPOT_SSID" \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "$HOTSPOT_PASSWORD"
    
    # 激活热点
    if nmcli connection up "$HOTSPOT_SSID"; then
        log_message "热点模式已启动: $HOTSPOT_SSID (192.168.4.1)"
        
        # 启用IP转发
        echo 1 > /proc/sys/net/ipv4/ip_forward
        
        # 配置iptables NAT规则
        iptables -t nat -A POSTROUTING -s 192.168.4.0/24 ! -d 192.168.4.0/24 -j MASQUERADE 2>/dev/null || true
        iptables -A FORWARD -s 192.168.4.0/24 -j ACCEPT 2>/dev/null || true
        iptables -A FORWARD -d 192.168.4.0/24 -j ACCEPT 2>/dev/null || true
    else
        log_message "热点启动失败"
        return 1
    fi
}

# 停止热点模式 (Ubuntu 24.04适配)
stop_hotspot() {
    log_message "停止热点模式..."
    
    # 停用热点连接
    nmcli connection down "$HOTSPOT_SSID" 2>/dev/null || true
    
    # 清理iptables规则
    iptables -t nat -D POSTROUTING -s 192.168.4.0/24 ! -d 192.168.4.0/24 -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -s 192.168.4.0/24 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d 192.168.4.0/24 -j ACCEPT 2>/dev/null || true
}

# 检查当前模式 (Ubuntu 24.04适配)
get_current_mode() {
    # 检查是否有活动的热点连接
    if nmcli connection show --active | grep -q "$HOTSPOT_SSID"; then
        echo "hotspot"
    # 检查是否有活动的WiFi连接
    elif nmcli device status | grep "$HOTSPOT_INTERFACE" | grep -q "connected"; then
        echo "wifi"
    else
        echo "disconnected"
    fi
}

# 主循环
main_loop() {
    log_message "WiFi热点自动切换服务启动"
    
    while true; do
        current_mode=$(get_current_mode)
        log_message "当前模式: $current_mode"
        
        case "$current_mode" in
            "wifi")
                # 已连接WiFi，检查网络是否正常
                if check_internet; then
                    log_message "WiFi连接正常"
                else
                    log_message "WiFi连接异常，尝试重新连接"
                    # 尝试重新连接
                    available_wifi=$(check_known_wifi)
                    if [ $? -eq 0 ]; then
                        connect_to_wifi "$available_wifi"
                    else
                        log_message "没有可用的已知WiFi，切换到热点模式"
                        start_hotspot
                    fi
                fi
                ;;
                
            "hotspot")
                # 热点模式，检查是否有可用WiFi
                available_wifi=$(check_known_wifi)
                if [ $? -eq 0 ]; then
                    log_message "发现可用WiFi: $available_wifi，尝试连接"
                    if connect_to_wifi "$available_wifi"; then
                        log_message "成功切换到WiFi模式"
                    else
                        log_message "WiFi连接失败，保持热点模式"
                        start_hotspot  # 确保热点正常运行
                    fi
                else
                    log_message "没有可用WiFi，保持热点模式"
                fi
                ;;
                
            "disconnected")
                # 未连接状态，优先尝试WiFi
                available_wifi=$(check_known_wifi)
                if [ $? -eq 0 ]; then
                    log_message "发现可用WiFi: $available_wifi"
                    if ! connect_to_wifi "$available_wifi"; then
                        log_message "WiFi连接失败，启动热点模式"
                        start_hotspot
                    fi
                else
                    log_message "没有可用WiFi，启动热点模式"
                    start_hotspot
                fi
                ;;
        esac
        
        sleep "$CHECK_INTERVAL"
    done
}

# 信号处理
cleanup() {
    log_message "收到退出信号，清理资源..."
    stop_hotspot
    exit 0
}

trap cleanup SIGTERM SIGINT

# 检查是否为root用户
if [ "$EUID" -ne 0 ]; then
    echo "请使用sudo运行此脚本"
    exit 1
fi

# 根据参数执行不同操作
case "${1:-auto}" in
    "start-hotspot")
        start_hotspot
        ;;
    "stop-hotspot")
        stop_hotspot
        ;;
    "connect-wifi")
        available_wifi=$(check_known_wifi)
        if [ $? -eq 0 ]; then
            connect_to_wifi "$available_wifi"
        else
            echo "没有可用的已知WiFi网络"
            exit 1
        fi
        ;;
    "status")
        current_mode=$(get_current_mode)
        echo "当前模式: $current_mode"
        if [ "$current_mode" = "wifi" ]; then
            echo "WiFi信息:"
            nmcli device show "$HOTSPOT_INTERFACE" | grep -E "(CONNECTION|IP4.ADDRESS)"
            wlan_ip=$(ip addr show "$HOTSPOT_INTERFACE" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
            echo "wlan0 IP地址: $wlan_ip"
        elif [ "$current_mode" = "hotspot" ]; then
            echo "热点信息:"
            echo "SSID: $HOTSPOT_SSID"
            wlan_ip=$(ip addr show "$HOTSPOT_INTERFACE" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
            echo "wlan0 IP地址: $wlan_ip"
        fi
        ;;
    "auto"|*)
        main_loop
        ;;
esac
