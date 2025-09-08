#!/bin/bash
# Samba共享服务安装配置脚本

set -e

echo "=== 开始配置Samba共享服务 ==="

# 检查是否为root用户
if [ "$EUID" -ne 0 ]; then
    echo "请使用sudo运行此脚本"
    exit 1
fi

# 安装Samba
echo "1. 安装Samba服务..."
apt update
apt install -y samba samba-common-bin

# 停止服务进行配置
echo "2. 停止Samba服务进行配置..."
systemctl stop smbd nmbd

# 备份原配置文件
echo "3. 备份原配置文件..."
cp /etc/samba/smb.conf /etc/samba/smb.conf.backup.$(date +%Y%m%d_%H%M%S)

# 复制新配置文件
echo "4. 应用新配置文件..."
cp /home/pi/shumeipai/config/samba.conf /etc/samba/smb.conf

# 创建数据目录
echo "5. 创建数据目录..."
mkdir -p /home/pi/data/{submissions,uploads,logs}
chown -R pi:pi /home/pi/data
chmod -R 755 /home/pi/data

# 创建Samba用户
echo "6. 配置Samba用户..."
# 为pi用户设置Samba密码
echo "请为pi用户设置Samba密码:"
smbpasswd -a pi

# 创建专用数据用户
if ! id "datauser" &>/dev/null; then
    useradd -r -s /bin/false datauser
    echo "请为datauser设置Samba密码:"
    smbpasswd -a datauser
fi

# 测试配置文件
echo "7. 测试Samba配置..."
testparm -s

# 启动服务
echo "8. 启动Samba服务..."
systemctl start smbd nmbd
systemctl enable smbd nmbd


# 显示服务状态
echo "9. 检查服务状态..."
systemctl status smbd --no-pager
systemctl status nmbd --no-pager

# 显示共享列表
echo "10. 显示可用共享..."
smbclient -L localhost -U%

echo ""
echo "=== Samba配置完成 ==="
echo ""
echo "可用共享目录:"
echo "  \\\\$(hostname -I | awk '{print $1}')\\data-readonly    (只读访问，无需密码)"
echo "  \\\\$(hostname -I | awk '{print $1}')\\data-readwrite   (读写访问，需要密码)"
echo "  \\\\$(hostname -I | awk '{print $1}')\\submissions      (提交数据，只读)"
echo "  \\\\$(hostname -I | awk '{print $1}')\\uploads          (上传文件，只读)"
echo ""
echo "Windows访问方法:"
echo "  1. 打开文件资源管理器"
echo "  2. 在地址栏输入: \\\\$(hostname -I | awk '{print $1}')"
echo "  3. 输入用户名密码进行访问"
echo ""
echo "用户账户:"
echo "  - pi: 管理员账户，可访问所有共享"
echo "  - datauser: 数据用户，可读写数据目录"
echo "  - 匿名: 可只读访问部分共享"
echo ""
