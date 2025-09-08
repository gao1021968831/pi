#!/bin/bash
# 树莓派数据收集系统一键安装脚本

set -e

echo "=== 树莓派数据收集系统安装 ==="

# 检查权限
if [ "$EUID" -ne 0 ]; then
    echo "请使用sudo运行此脚本"
    exit 1
fi

# 获取当前用户
REAL_USER=${SUDO_USER:-$USER}
USER_HOME="/home/$REAL_USER"

echo "当前用户: $REAL_USER"
echo "用户目录: $USER_HOME"

# 更新系统
echo "1. 更新系统..."
apt update && apt upgrade -y

# 安装基础软件包
echo "2. 安装基础软件包..."
apt install -y python3-pip python3-venv python3-flask python3-sqlite3 \
    samba samba-common-bin hostapd dnsmasq \
    git vim htop curl wget unzip

# 安装Python依赖
echo "3. 安装Python依赖..."
pip3 install flask qrcode[pil] requests pillow

# 创建数据目录
echo "4. 创建数据目录..."
mkdir -p "$USER_HOME/data"/{submissions,uploads,logs,config,backups}
chown -R "$REAL_USER:$REAL_USER" "$USER_HOME/data"
chmod -R 755 "$USER_HOME/data"

# 创建systemd服务文件
echo "5. 创建系统服务..."

# Flask服务
cat > /etc/systemd/system/flask-server.service << EOF
[Unit]
Description=Flask Data Collection Server
After=network.target

[Service]
Type=simple
User=$REAL_USER
WorkingDirectory=$USER_HOME/shumeipai/flask_server
ExecStart=/usr/bin/python3 app.py
Restart=always
RestartSec=10
Environment=PYTHONPATH=$USER_HOME/shumeipai/flask_server

[Install]
WantedBy=multi-user.target
EOF

# 云端同步服务
cat > /etc/systemd/system/cloud-sync.service << EOF
[Unit]
Description=Cloud Data Sync Service
After=network.target

[Service]
Type=oneshot
User=$REAL_USER
WorkingDirectory=$USER_HOME/shumeipai/scripts
ExecStart=/usr/bin/python3 cloud_sync.py
EOF

# 云端同步定时器
cat > /etc/systemd/system/cloud-sync.timer << EOF
[Unit]
Description=Run cloud sync every 5 minutes
Requires=cloud-sync.service

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
EOF

# WiFi热点服务
cat > /etc/systemd/system/wifi-hotspot.service << EOF
[Unit]
Description=WiFi Hotspot Auto Switch Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$USER_HOME/shumeipai/scripts/wifi_hotspot.sh
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

# 配置hostapd
echo "6. 配置WiFi热点..."
cat > /etc/hostapd/hostapd.conf << EOF
interface=wlan0
driver=nl80211
ssid=RasPi-DataCollector
hw_mode=g
channel=7
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=raspberry2024
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOF

# 配置dnsmasq
echo "7. 配置DHCP服务..."
cp /etc/dnsmasq.conf /etc/dnsmasq.conf.backup
cat >> /etc/dnsmasq.conf << EOF

# 树莓派热点配置
interface=wlan0
dhcp-range=192.168.4.2,192.168.4.20,255.255.255.0,24h
EOF

# 配置Samba
echo "8. 配置Samba服务..."
cp /etc/samba/smb.conf /etc/samba/smb.conf.backup
cp "$USER_HOME/shumeipai/config/samba.conf" /etc/samba/smb.conf

# 设置脚本权限
echo "9. 设置脚本权限..."
chmod +x "$USER_HOME/shumeipai/scripts"/*.sh

# 重新加载systemd
echo "10. 启用系统服务..."
systemctl daemon-reload

# 启用服务
systemctl enable flask-server
systemctl enable cloud-sync.timer
systemctl enable smbd nmbd
systemctl enable wifi-hotspot

# 启动服务
systemctl start flask-server
systemctl start cloud-sync.timer
systemctl start smbd nmbd
systemctl start wifi-hotspot

# 配置防火墙
echo "11. 配置防火墙..."
ufw --force enable
ufw allow 22    # SSH
ufw allow 80    # HTTP
ufw allow 5000  # Flask
ufw allow 445   # Samba
ufw allow 139   # Samba
ufw allow 53    # DNS
ufw allow 67    # DHCP

# 创建默认云端配置
echo "12. 创建默认配置..."
cat > "$USER_HOME/data/config/cloud_config.json" << EOF
{
  "api_key": "",
  "api_secret": "",
  "sync_enabled": false,
  "last_sync_time": null,
  "sync_interval": 300,
  "auto_sync": true
}
EOF

chown "$REAL_USER:$REAL_USER" "$USER_HOME/data/config/cloud_config.json"

# 显示安装结果
echo ""
echo "=== 安装完成 ==="
echo ""
echo "系统信息:"
echo "  主机名: $(hostname)"
echo "  IP地址: $(hostname -I | awk '{print $1}')"
echo ""
echo "Web服务:"
echo "  数据收集: http://$(hostname -I | awk '{print $1}'):5000"
echo "  管理面板: http://$(hostname -I | awk '{print $1}'):5000/admin"
echo ""
echo "Samba共享:"
echo "  访问地址: \\\\$(hostname -I | awk '{print $1}')"
echo "  只读共享: data-readonly (无需密码)"
echo "  读写共享: data-readwrite (需要密码)"
echo ""
echo "WiFi热点:"
echo "  热点名称: RasPi-DataCollector"
echo "  热点密码: raspberry2024"
echo "  热点IP: 192.168.4.1"
echo ""
echo "服务状态:"
systemctl is-active flask-server && echo "  ✓ Flask服务器已启动" || echo "  ✗ Flask服务器启动失败"
systemctl is-active smbd && echo "  ✓ Samba服务已启动" || echo "  ✗ Samba服务启动失败"
systemctl is-active wifi-hotspot && echo "  ✓ WiFi热点服务已启动" || echo "  ✗ WiFi热点服务启动失败"
systemctl is-active cloud-sync.timer && echo "  ✓ 云端同步定时器已启动" || echo "  ✗ 云端同步定时器启动失败"
echo ""
echo "下一步操作:"
echo "1. 设置Samba用户密码: sudo smbpasswd -a $REAL_USER"
echo "2. 配置云端API: 编辑 $USER_HOME/data/config/cloud_config.json"
echo "3. 访问Web界面测试功能"
echo "4. 创建系统备份: sudo $USER_HOME/shumeipai/scripts/system_backup.sh"
echo ""
