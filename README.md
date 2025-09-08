# 树莓派4B离线数据收集系统

## 项目概述
这是一个基于树莓派4B的离线数据收集系统，支持手机扫码离线提交数据，Windows电脑直接访问，联网后自动同步到云端。

## 核心功能
1. **系统配置** - 树莓派系统安装与热点自动连接
2. **数据收集** - Flask服务器接收手机扫码提交的数据
3. **文件共享** - Samba服务让Windows电脑直接访问数据
4. **云端同步** - 联网后自动同步本地数据到草料云端
5. **系统备份** - 制作系统镜像便于快速部署

## 验收标准
✅ 离线提交数据 → ✅ 电脑能查到 → ✅ 联网自动传云端

## 项目结构
```
shumeipai/
├── docs/                    # 文档目录
│   ├── 01-系统安装指南.md
│   ├── 02-服务配置指南.md
│   └── 03-使用说明.md
├── flask_server/           # Flask服务器
│   ├── app.py
│   ├── templates/
│   └── static/
├── scripts/               # 自动化脚本
│   ├── wifi_hotspot.sh
│   ├── cloud_sync.py
│   └── system_backup.sh
├── config/               # 配置文件
│   ├── samba.conf
│   └── systemd/
└── data/                # 数据存储目录
    ├── submissions/     # 提交的数据
    └── logs/           # 系统日志
```

## 快速开始
1. 按照 `docs/01-系统安装指南.md` 安装系统
2. 运行 `scripts/setup.sh` 自动配置所有服务
3. 访问树莓派IP地址开始使用

## 技术栈
- **操作系统**: Raspberry Pi OS
- **Web服务**: Flask + Nginx
- **文件共享**: Samba
- **数据库**: SQLite
- **云端API**: 草料二维码API
