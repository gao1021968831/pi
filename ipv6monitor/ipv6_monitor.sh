#!/bin/bash

# IPv6网络连通性监控脚本
# 功能：检测eth0和wlan0网卡的IPv6连通性，如果不通则重新获取IPv6地址

# 配置参数
INTERFACES=("eth0" "wlan0")
LOG_FILE="/var/log/ipv6_monitor.log"
TEST_HOST="2606:4700:4700::1111"  # Google的IPv6 DNS服务器
PING_COUNT=3
PING_TIMEOUT=5
DELETE_128_ADDRESSES=true  # 是否删除/128掩码的IPv6地址

# 日志函数
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# 检查网卡是否存在
check_interface_exists() {
    local interface="$1"
    if ! ip link show "$interface" &>/dev/null; then
        log_message "WARNING" "网卡 $interface 不存在，跳过检测"
        return 1
    fi
    return 0
}

# 检查网卡是否启用
check_interface_up() {
    local interface="$1"
    if ! ip link show "$interface" | grep -q "state UP"; then
        log_message "WARNING" "网卡 $interface 未启用，跳过检测"
        return 1
    fi
    return 0
}

# 获取网卡的IPv6地址（包含掩码信息）
get_ipv6_addresses() {
    local interface="$1"
    ip -6 addr show "$interface" | grep -E "inet6.*scope global" | awk '{print $2}'
}

# 获取网卡的IPv6地址（仅地址部分）
get_ipv6_addresses_only() {
    local interface="$1"
    get_ipv6_addresses "$interface" | cut -d'/' -f1
}

# 检查IPv6地址是否为有效的全局地址
is_valid_global_ipv6() {
    local addr_with_mask="$1"
    local addr=$(echo "$addr_with_mask" | cut -d'/' -f1)
    local mask=$(echo "$addr_with_mask" | cut -d'/' -f2)
    
    # 根据配置决定是否接受/128掩码的地址
    if [ "$mask" = "128" ] && [ "$DELETE_128_ADDRESSES" != "true" ]; then
        return 1
    fi
    
    # 检查是否为全局单播地址（2000::/3）
    if echo "$addr" | grep -qE "^[23][0-9a-fA-F]{3}:"; then
        return 0
    fi
    
    return 1
}

# 测试IPv6连通性（改进版，增加容错机制）
test_ipv6_connectivity() {
    local interface="$1"
    local max_retries=2
    local retry_count=0
    
    # 获取有效的IPv6地址进行测试
    local valid_addresses=$(get_ipv6_addresses "$interface")
    local has_valid_addr=false
    
    if [ -n "$valid_addresses" ]; then
        while IFS= read -r addr_with_mask; do
            if [ -n "$addr_with_mask" ] && is_valid_global_ipv6 "$addr_with_mask"; then
                has_valid_addr=true
                break
            fi
        done <<< "$valid_addresses"
    fi
    
    # 如果没有有效地址，直接返回失败
    if [ "$has_valid_addr" = false ]; then
        log_message "WARNING" "网卡 $interface 没有有效的全局IPv6地址用于连通性测试"
        return 1
    fi
    
    # 多次尝试ping测试，允许部分失败
    while [ $retry_count -le $max_retries ]; do
        local ping_output
        ping_output=$(ping6 -c "$PING_COUNT" -W "$PING_TIMEOUT" -I "$interface" "$TEST_HOST" 2>&1)
        local ping_result=$?
        
        # 分析ping结果
        local success_count=$(echo "$ping_output" | grep -c "bytes from")
        local unreachable_count=$(echo "$ping_output" | grep -c "Destination unreachable")
        
        log_message "INFO" "网卡 $interface ping测试结果: 成功 $success_count/$PING_COUNT 包，不可达 $unreachable_count 包"
        
        # 如果至少有一半的包成功，认为连接正常
        if [ $success_count -ge $((PING_COUNT / 2)) ]; then
            if [ $unreachable_count -gt 0 ]; then
                log_message "WARNING" "网卡 $interface 连接不稳定但可用 (成功率: $success_count/$PING_COUNT)"
            fi
            return 0
        fi
        
        # 如果完全失败，等待后重试
        if [ $ping_result -ne 0 ] && [ $retry_count -lt $max_retries ]; then
            retry_count=$((retry_count + 1))
            log_message "WARNING" "网卡 $interface 连通性测试失败，等待5秒后重试 ($retry_count/$max_retries)"
            sleep 5
        else
            break
        fi
    done
    
    log_message "ERROR" "网卡 $interface 连通性测试最终失败"
    return 1
}

# 删除IPv6地址
delete_ipv6_addresses() {
    local interface="$1"
    local addresses=$(get_ipv6_addresses "$interface")
    
    if [ -z "$addresses" ]; then
        log_message "INFO" "网卡 $interface 没有全局IPv6地址需要删除"
        return 0
    fi
    
    log_message "INFO" "开始删除网卡 $interface 的IPv6地址"
    while IFS= read -r addr_with_mask; do
        if [ -n "$addr_with_mask" ]; then
            local addr=$(echo "$addr_with_mask" | cut -d'/' -f1)
            local mask=$(echo "$addr_with_mask" | cut -d'/' -f2)
            
            # 根据配置决定是否删除/128掩码的地址
            if [ "$mask" = "128" ] && [ "$DELETE_128_ADDRESSES" != "true" ]; then
                log_message "INFO" "跳过/128掩码地址: $addr_with_mask (临时地址)"
                continue
            fi
            
            # 如果是/128地址且配置为删除，则特别标注
            if [ "$mask" = "128" ]; then
                log_message "WARNING" "删除/128掩码地址: $addr_with_mask (可能是临时地址或主机路由)"
            fi
            
            log_message "INFO" "删除IPv6地址: $addr_with_mask"
            if ip -6 addr delete "$addr_with_mask" dev "$interface" 2>/dev/null; then
                log_message "SUCCESS" "成功删除IPv6地址: $addr_with_mask"
            else
                log_message "ERROR" "删除IPv6地址失败: $addr_with_mask"
            fi
        fi
    done <<< "$addresses"
}

# 清理现有的dhclient进程
cleanup_dhclient_processes() {
    local interface="$1"
    
    # 查找并终止现有的dhclient -6进程
    local pids=$(pgrep -f "dhclient.*-6.*$interface")
    if [ -n "$pids" ]; then
        log_message "INFO" "发现网卡 $interface 的dhclient进程: $pids"
        for pid in $pids; do
            log_message "INFO" "终止dhclient进程: $pid"
            kill -TERM "$pid" 2>/dev/null
            sleep 2
            # 如果进程仍然存在，强制终止
            if kill -0 "$pid" 2>/dev/null; then
                log_message "WARNING" "强制终止dhclient进程: $pid"
                kill -KILL "$pid" 2>/dev/null
            fi
        done
        sleep 3
    fi
}

# 重新获取IPv6地址（改进版，增加进程管理）
renew_ipv6_address() {
    local interface="$1"
    
    log_message "INFO" "开始为网卡 $interface 重新获取IPv6地址"
    
    # 清理现有的dhclient进程
    cleanup_dhclient_processes "$interface"
    
    # 使用dhclient重新获取IPv6地址
    log_message "INFO" "启动dhclient -6 $interface"
    if timeout 30 dhclient -6 "$interface" 2>/dev/null; then
        log_message "SUCCESS" "成功为网卡 $interface 重新获取IPv6地址"
        
        # 等待一段时间让地址配置生效
        sleep 5
        
        # 显示新获取的IPv6地址
        local new_addresses=$(get_ipv6_addresses "$interface")
        if [ -n "$new_addresses" ]; then
            log_message "INFO" "网卡 $interface 新的IPv6地址:"
            while IFS= read -r addr_with_mask; do
                if [ -n "$addr_with_mask" ]; then
                    local addr=$(echo "$addr_with_mask" | cut -d'/' -f1)
                    local mask=$(echo "$addr_with_mask" | cut -d'/' -f2)
                    if is_valid_global_ipv6 "$addr_with_mask"; then
                        log_message "INFO" "  - $addr_with_mask (有效地址)"
                    else
                        log_message "INFO" "  - $addr_with_mask (临时地址)"
                    fi
                fi
            done <<< "$new_addresses"
        fi
        return 0
    else
        log_message "ERROR" "为网卡 $interface 重新获取IPv6地址失败"
        # 清理可能残留的进程
        cleanup_dhclient_processes "$interface"
        return 1
    fi
}

# 处理单个网卡
process_interface() {
    local interface="$1"
    
    log_message "INFO" "开始检测网卡: $interface"
    
    # 检查网卡是否存在和启用
    if ! check_interface_exists "$interface" || ! check_interface_up "$interface"; then
        return 1
    fi
    
    # 检查是否有有效的IPv6地址
    local ipv6_addresses=$(get_ipv6_addresses "$interface")
    local valid_addresses=""
    
    if [ -n "$ipv6_addresses" ]; then
        while IFS= read -r addr_with_mask; do
            if [ -n "$addr_with_mask" ] && is_valid_global_ipv6 "$addr_with_mask"; then
                valid_addresses="$valid_addresses$addr_with_mask\n"
            fi
        done <<< "$ipv6_addresses"
    fi
    
    if [ -z "$valid_addresses" ]; then
        log_message "WARNING" "网卡 $interface 没有有效的全局IPv6地址，尝试获取"
        renew_ipv6_address "$interface"
        return $?
    fi
    
    log_message "INFO" "网卡 $interface 当前IPv6地址:"
    while IFS= read -r addr_with_mask; do
        if [ -n "$addr_with_mask" ]; then
            local addr=$(echo "$addr_with_mask" | cut -d'/' -f1)
            local mask=$(echo "$addr_with_mask" | cut -d'/' -f2)
            if [ "$mask" = "128" ]; then
                log_message "INFO" "  - $addr_with_mask (临时地址，跳过)"
            else
                log_message "INFO" "  - $addr_with_mask (有效地址)"
            fi
        fi
    done <<< "$ipv6_addresses"
    
    # 测试连通性
    if test_ipv6_connectivity "$interface"; then
        log_message "SUCCESS" "网卡 $interface IPv6连通性正常"
        return 0
    else
        log_message "WARNING" "网卡 $interface IPv6连通性异常，等待30秒后再次测试"
        
        # 等待30秒后再次测试，避免因临时网络波动而重新配置
        sleep 30
        
        if test_ipv6_connectivity "$interface"; then
            log_message "SUCCESS" "网卡 $interface IPv6连通性已恢复，无需重新配置"
            return 0
        fi
        
        log_message "WARNING" "网卡 $interface IPv6连通性持续异常，开始重新配置"
        
        # 删除现有IPv6地址
        delete_ipv6_addresses "$interface"
        
        # 重新获取IPv6地址
        if renew_ipv6_address "$interface"; then
            # 再次测试连通性
            sleep 10
            if test_ipv6_connectivity "$interface"; then
                log_message "SUCCESS" "网卡 $interface IPv6连通性恢复正常"
                return 0
            else
                log_message "ERROR" "网卡 $interface IPv6连通性仍然异常"
                return 1
            fi
        else
            return 1
        fi
    fi
}

# 主函数
main() {
    log_message "INFO" "========== IPv6网络监控开始 =========="
    
    # 检查是否以root权限运行
    if [ "$EUID" -ne 0 ]; then
        log_message "ERROR" "此脚本需要root权限运行"
        exit 1
    fi
    
    # 检查必要的命令是否存在
    for cmd in ping6 ip dhclient; do
        if ! command -v "$cmd" &>/dev/null; then
            log_message "ERROR" "缺少必要的命令: $cmd"
            exit 1
        fi
    done
    
    # 创建日志目录
    mkdir -p "$(dirname "$LOG_FILE")"
    
    local success_count=0
    local total_count=0
    
    # 处理每个网卡
    for interface in "${INTERFACES[@]}"; do
        ((total_count++))
        if process_interface "$interface"; then
            ((success_count++))
        fi
        echo  # 添加空行分隔不同网卡的日志
    done
    
    log_message "INFO" "处理完成: $success_count/$total_count 个网卡IPv6连通性正常"
    log_message "INFO" "========== IPv6网络监控结束 =========="
    
    # 如果所有网卡都失败，返回错误码
    if [ "$success_count" -eq 0 ] && [ "$total_count" -gt 0 ]; then
        exit 1
    fi
}

# 运行主函数
main "$@"

