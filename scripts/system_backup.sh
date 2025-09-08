#!/bin/bash
# 树莓派系统镜像备份脚本
# 创建完整的系统镜像用于快速部署

set -e

# 配置参数
BACKUP_DIR="/apps/pi/backups"
IMAGE_NAME="raspi-datacollector-$(date +%Y%m%d_%H%M%S).img"
LOG_FILE="/apps/pi/backup.log"
COMPRESSION="gzip"  # 可选: gzip, xz, none

# 日志函数
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# 检查磁盘空间
check_disk_space() {
    local required_space_gb=8  # 至少需要8GB空间
    local available_space=$(df /apps/pi --output=avail | tail -1)
    local available_gb=$((available_space / 1024 / 1024))
    
    if [ $available_gb -lt $required_space_gb ]; then
        log_message "错误: 磁盘空间不足，需要至少${required_space_gb}GB，当前可用${available_gb}GB"
        return 1
    fi
    
    log_message "磁盘空间检查通过: ${available_gb}GB 可用"
    return 0
}

# 创建系统镜像
create_system_image() {
    log_message "开始创建系统镜像..."
    
    # 确保备份目录存在
    mkdir -p "$BACKUP_DIR"
    
    # 获取根分区设备
    local root_device=$(findmnt -n -o SOURCE /)
    local disk_device=$(lsblk -no pkname "$root_device" | head -1)
    local full_device="/dev/$disk_device"
    
    log_message "检测到系统磁盘: $full_device"
    
    # 获取磁盘大小
    local disk_size=$(blockdev --getsize64 "$full_device")
    local disk_size_gb=$((disk_size / 1024 / 1024 / 1024))
    
    log_message "磁盘大小: ${disk_size_gb}GB"
    
    # 创建镜像文件路径
    local image_path="$BACKUP_DIR/$IMAGE_NAME"
    
    # 使用dd创建镜像
    log_message "正在创建镜像文件: $image_path"
    log_message "这可能需要较长时间，请耐心等待..."
    
    if [ "$COMPRESSION" = "gzip" ]; then
        dd if="$full_device" bs=4M status=progress | gzip > "${image_path}.gz"
        image_path="${image_path}.gz"
    elif [ "$COMPRESSION" = "xz" ]; then
        dd if="$full_device" bs=4M status=progress | xz -z > "${image_path}.xz"
        image_path="${image_path}.xz"
    else
        dd if="$full_device" of="$image_path" bs=4M status=progress
    fi
    
    log_message "镜像创建完成: $image_path"
    
    # 生成校验和
    log_message "生成校验和..."
    local checksum=$(sha256sum "$image_path" | cut -d' ' -f1)
    echo "$checksum  $(basename "$image_path")" > "${image_path}.sha256"
    
    log_message "校验和: $checksum"
    
    # 创建镜像信息文件
    create_image_info "$image_path"
    
    return 0
}

# 创建镜像信息文件
create_image_info() {
    local image_path="$1"
    local info_file="${image_path}.info"
    
    log_message "创建镜像信息文件: $info_file"
    
    cat > "$info_file" << EOF
# 树莓派数据收集系统镜像信息
创建时间: $(date '+%Y-%m-%d %H:%M:%S')
镜像文件: $(basename "$image_path")
系统版本: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)
内核版本: $(uname -r)
硬件型号: $(cat /proc/cpuinfo | grep "Model" | head -1 | cut -d':' -f2 | xargs)
磁盘大小: $(lsblk -b -d -o SIZE /dev/mmcblk0 | tail -1 | numfmt --to=iec)
压缩方式: $COMPRESSION

# 包含的服务和功能
- Flask数据收集服务器 (端口5000)
- Samba文件共享服务
- WiFi热点自动切换
- 云端数据同步
- 系统监控和日志

# 默认用户账户
- pi: 系统管理员 (密码需要重新设置)
- datauser: 数据访问用户 (Samba专用)

# 网络配置
- 热点SSID: RasPi-DataCollector
- 热点密码: raspberry2024
- 热点IP: 192.168.4.1
- Web服务: http://树莓派IP:5000

# 恢复说明
1. 使用 Raspberry Pi Imager 或 dd 命令烧录到SD卡
2. 首次启动后运行: sudo /home/pi/shumeipai/scripts/setup.sh
3. 配置WiFi和云端API密钥
4. 修改默认密码和安全设置

# 文件位置
- 项目目录: /home/pi/shumeipai/
- 数据目录: /home/pi/data/
- 配置文件: /home/pi/data/config/
- 日志文件: /home/pi/data/logs/

EOF

    log_message "镜像信息文件创建完成"
}

# 压缩旧备份
compress_old_backups() {
    log_message "检查旧备份文件..."
    
    # 查找7天前的未压缩镜像文件
    find "$BACKUP_DIR" -name "*.img" -mtime +7 -type f | while read -r old_image; do
        log_message "压缩旧镜像: $(basename "$old_image")"
        gzip "$old_image"
    done
    
    # 删除30天前的备份
    find "$BACKUP_DIR" -name "*.img.*" -mtime +30 -type f | while read -r old_backup; do
        log_message "删除过期备份: $(basename "$old_backup")"
        rm -f "$old_backup"
        rm -f "${old_backup}.sha256" 2>/dev/null || true
        rm -f "${old_backup}.info" 2>/dev/null || true
    done
}

# 创建快速部署脚本
create_deployment_script() {
    local deploy_script="$BACKUP_DIR/deploy_image.sh"
    
    log_message "创建部署脚本: $deploy_script"
    
    cat > "$deploy_script" << 'EOF'
#!/bin/bash
# 快速部署脚本

set -e

if [ $# -ne 2 ]; then
    echo "用法: $0 <镜像文件> <目标设备>"
    echo "示例: $0 raspi-datacollector-20241208.img.gz /dev/sdb"
    exit 1
fi

IMAGE_FILE="$1"
TARGET_DEVICE="$2"

# 检查文件是否存在
if [ ! -f "$IMAGE_FILE" ]; then
    echo "错误: 镜像文件不存在: $IMAGE_FILE"
    exit 1
fi

# 检查目标设备
if [ ! -b "$TARGET_DEVICE" ]; then
    echo "错误: 目标设备不存在: $TARGET_DEVICE"
    exit 1
fi

echo "警告: 这将完全覆盖目标设备 $TARGET_DEVICE 上的所有数据!"
read -p "确定要继续吗? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "操作已取消"
    exit 0
fi

echo "开始烧录镜像到 $TARGET_DEVICE ..."

# 根据文件扩展名选择解压方式
case "$IMAGE_FILE" in
    *.gz)
        gunzip -c "$IMAGE_FILE" | dd of="$TARGET_DEVICE" bs=4M status=progress
        ;;
    *.xz)
        xz -dc "$IMAGE_FILE" | dd of="$TARGET_DEVICE" bs=4M status=progress
        ;;
    *.img)
        dd if="$IMAGE_FILE" of="$TARGET_DEVICE" bs=4M status=progress
        ;;
    *)
        echo "错误: 不支持的文件格式"
        exit 1
        ;;
esac

# 同步数据
sync

echo "镜像烧录完成!"
echo ""
echo "后续步骤:"
echo "1. 将SD卡插入树莓派并启动"
echo "2. SSH连接: ssh pi@树莓派IP"
echo "3. 运行初始化: sudo /home/pi/shumeipai/scripts/setup.sh"
echo "4. 访问Web界面: http://树莓派IP:5000"
EOF

    chmod +x "$deploy_script"
    log_message "部署脚本创建完成"
}

# 主函数
main() {
    log_message "=== 系统备份开始 ==="
    
    # 检查权限
    if [ "$EUID" -ne 0 ]; then
        echo "请使用sudo运行此脚本"
        exit 1
    fi
    
    # 创建日志目录
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # 检查磁盘空间
    if ! check_disk_space; then
        exit 1
    fi
    
    # 清理旧备份
    compress_old_backups
    
    # 创建系统镜像
    if create_system_image; then
        log_message "系统镜像创建成功"
    else
        log_message "系统镜像创建失败"
        exit 1
    fi
    
    # 创建部署脚本
    create_deployment_script
    
    # 显示备份信息
    log_message "备份完成，文件位置: $BACKUP_DIR"
    ls -lh "$BACKUP_DIR"/*.img* 2>/dev/null | tail -5
    
    log_message "=== 系统备份结束 ==="
}

# 根据参数执行不同操作
case "${1:-backup}" in
    "backup")
        main
        ;;
    "list")
        echo "可用备份镜像:"
        ls -lh "$BACKUP_DIR"/*.img* 2>/dev/null || echo "没有找到备份文件"
        ;;
    "cleanup")
        echo "清理过期备份..."
        compress_old_backups
        ;;
    "info")
        if [ -n "$2" ] && [ -f "$2.info" ]; then
            cat "$2.info"
        else
            echo "用法: $0 info <镜像文件路径>"
        fi
        ;;
    *)
        echo "用法: $0 {backup|list|cleanup|info}"
        echo "  backup  - 创建系统镜像备份"
        echo "  list    - 列出可用备份"
        echo "  cleanup - 清理过期备份"
        echo "  info    - 显示镜像信息"
        ;;
esac
