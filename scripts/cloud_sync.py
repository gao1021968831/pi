#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
云端数据同步脚本 - 草料二维码API
自动将本地数据同步到草料云端
"""

import sqlite3
import json
import requests
import time
import logging
import os
from datetime import datetime
import hashlib
import subprocess

# 配置
CONFIG = {
    'db_path': '/home/pi/data/submissions.db',
    'log_path': '/home/pi/data/logs/cloud_sync.log',
    'config_path': '/home/pi/data/config/cloud_config.json',
    'api_base_url': 'https://api.cli.im',  # 草料二维码API
    'max_retries': 3,
    'retry_delay': 5,  # 秒
    'batch_size': 10,  # 每批同步数量
}

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(CONFIG['log_path']),
        logging.StreamHandler()
    ]
)

class CloudSyncManager:
    def __init__(self):
        self.config = self.load_config()
        self.session = requests.Session()
        self.session.headers.update({
            'User-Agent': 'RaspberryPi-DataCollector/1.0',
            'Content-Type': 'application/json'
        })
        
    def load_config(self):
        """加载云端配置"""
        try:
            if os.path.exists(CONFIG['config_path']):
                with open(CONFIG['config_path'], 'r', encoding='utf-8') as f:
                    return json.load(f)
            else:
                # 创建默认配置
                default_config = {
                    'api_key': '',
                    'api_secret': '',
                    'sync_enabled': False,
                    'last_sync_time': None,
                    'sync_interval': 300,  # 5分钟
                    'auto_sync': True
                }
                self.save_config(default_config)
                return default_config
        except Exception as e:
            logging.error(f"加载配置失败: {e}")
            return {}
    
    def save_config(self, config):
        """保存配置"""
        try:
            os.makedirs(os.path.dirname(CONFIG['config_path']), exist_ok=True)
            with open(CONFIG['config_path'], 'w', encoding='utf-8') as f:
                json.dump(config, f, ensure_ascii=False, indent=2)
        except Exception as e:
            logging.error(f"保存配置失败: {e}")
    
    def check_network_connection(self):
        """检查网络连接"""
        try:
            # 检查是否能连接到互联网
            response = subprocess.run(['ping', '-c', '1', '8.8.8.8'], 
                                   capture_output=True, timeout=10)
            return response.returncode == 0
        except:
            return False
    
    def get_unsynced_submissions(self):
        """获取未同步的数据"""
        try:
            conn = sqlite3.connect(CONFIG['db_path'])
            cursor = conn.cursor()
            
            cursor.execute('''
                SELECT id, timestamp, form_type, data, files, ip_address
                FROM submissions 
                WHERE synced_to_cloud = FALSE
                ORDER BY timestamp ASC
                LIMIT ?
            ''', (CONFIG['batch_size'],))
            
            submissions = []
            for row in cursor.fetchall():
                submission = {
                    'id': row[0],
                    'timestamp': row[1],
                    'form_type': row[2],
                    'data': json.loads(row[3]) if row[3] else {},
                    'files': json.loads(row[4]) if row[4] else [],
                    'ip_address': row[5]
                }
                submissions.append(submission)
            
            conn.close()
            return submissions
            
        except Exception as e:
            logging.error(f"获取未同步数据失败: {e}")
            return []
    
    def generate_signature(self, data, timestamp):
        """生成API签名"""
        try:
            api_secret = self.config.get('api_secret', '')
            if not api_secret:
                return None
                
            # 创建签名字符串
            sign_string = f"{json.dumps(data, sort_keys=True)}{timestamp}{api_secret}"
            return hashlib.md5(sign_string.encode('utf-8')).hexdigest()
        except Exception as e:
            logging.error(f"生成签名失败: {e}")
            return None
    
    def sync_to_cloud(self, submission):
        """同步单条数据到云端"""
        try:
            if not self.config.get('api_key') or not self.config.get('api_secret'):
                logging.warning("未配置API密钥，跳过云端同步")
                return False
            
            # 准备同步数据
            sync_data = {
                'source': 'raspberry_pi',
                'submission_id': submission['id'],
                'timestamp': submission['timestamp'],
                'form_type': submission['form_type'],
                'data': submission['data'],
                'ip_address': submission['ip_address'],
                'device_info': {
                    'hostname': os.uname().nodename,
                    'platform': 'raspberry_pi_4b'
                }
            }
            
            # 添加文件信息（不上传实际文件，只记录文件信息）
            if submission['files']:
                sync_data['files'] = [
                    {
                        'name': f['original_name'],
                        'size': f['size'],
                        'type': f['original_name'].split('.')[-1] if '.' in f['original_name'] else 'unknown'
                    }
                    for f in submission['files']
                ]
            
            # 生成时间戳和签名
            timestamp = int(time.time())
            signature = self.generate_signature(sync_data, timestamp)
            
            if not signature:
                logging.error("无法生成API签名")
                return False
            
            # 准备API请求
            api_data = {
                'api_key': self.config['api_key'],
                'timestamp': timestamp,
                'signature': signature,
                'data': sync_data
            }
            
            # 发送到云端
            for attempt in range(CONFIG['max_retries']):
                try:
                    response = self.session.post(
                        f"{CONFIG['api_base_url']}/data/submit",
                        json=api_data,
                        timeout=30
                    )
                    
                    if response.status_code == 200:
                        result = response.json()
                        if result.get('success'):
                            logging.info(f"数据同步成功: ID {submission['id']}")
                            return True
                        else:
                            logging.error(f"云端返回错误: {result.get('message')}")
                    else:
                        logging.error(f"HTTP错误: {response.status_code}")
                        
                except requests.exceptions.RequestException as e:
                    logging.error(f"网络请求失败 (尝试 {attempt + 1}/{CONFIG['max_retries']}): {e}")
                    if attempt < CONFIG['max_retries'] - 1:
                        time.sleep(CONFIG['retry_delay'])
            
            return False
            
        except Exception as e:
            logging.error(f"同步数据失败: {e}")
            return False
    
    def mark_as_synced(self, submission_id):
        """标记数据为已同步"""
        try:
            conn = sqlite3.connect(CONFIG['db_path'])
            cursor = conn.cursor()
            
            cursor.execute('''
                UPDATE submissions 
                SET synced_to_cloud = TRUE, sync_timestamp = CURRENT_TIMESTAMP
                WHERE id = ?
            ''', (submission_id,))
            
            conn.commit()
            conn.close()
            
        except Exception as e:
            logging.error(f"标记同步状态失败: {e}")
    
    def sync_all_pending(self):
        """同步所有待同步数据"""
        if not self.check_network_connection():
            logging.warning("网络连接不可用，跳过同步")
            return False
        
        if not self.config.get('sync_enabled'):
            logging.info("云端同步已禁用")
            return False
        
        logging.info("开始同步待同步数据...")
        
        submissions = self.get_unsynced_submissions()
        if not submissions:
            logging.info("没有待同步数据")
            return True
        
        success_count = 0
        total_count = len(submissions)
        
        for submission in submissions:
            if self.sync_to_cloud(submission):
                self.mark_as_synced(submission['id'])
                success_count += 1
            else:
                logging.error(f"同步失败: ID {submission['id']}")
            
            # 避免API限流
            time.sleep(1)
        
        logging.info(f"同步完成: {success_count}/{total_count} 成功")
        
        # 更新最后同步时间
        self.config['last_sync_time'] = datetime.now().isoformat()
        self.save_config(self.config)
        
        return success_count == total_count
    
    def create_qr_code_for_data(self, submission):
        """为数据创建二维码（草料二维码服务）"""
        try:
            if not self.config.get('api_key'):
                return None
            
            # 创建数据查看URL
            data_url = f"http://data.local/view/{submission['id']}"
            
            qr_data = {
                'api_key': self.config['api_key'],
                'text': data_url,
                'size': '200x200',
                'format': 'png'
            }
            
            response = self.session.post(
                f"{CONFIG['api_base_url']}/qr/create",
                json=qr_data,
                timeout=10
            )
            
            if response.status_code == 200:
                result = response.json()
                if result.get('success'):
                    return result.get('qr_url')
            
            return None
            
        except Exception as e:
            logging.error(f"创建二维码失败: {e}")
            return None

def main():
    """主函数"""
    logging.info("=== 云端同步服务启动 ===")
    
    sync_manager = CloudSyncManager()
    
    # 检查配置
    if not sync_manager.config.get('api_key'):
        logging.warning("未配置API密钥，请编辑配置文件: " + CONFIG['config_path'])
        print(f"""
请配置云端同步参数:
1. 编辑配置文件: {CONFIG['config_path']}
2. 设置以下参数:
   - api_key: 草料二维码API密钥
   - api_secret: API密钥
   - sync_enabled: true
   
配置示例:
{{
  "api_key": "your_api_key_here",
  "api_secret": "your_api_secret_here", 
  "sync_enabled": true,
  "auto_sync": true,
  "sync_interval": 300
}}
        """)
        return
    
    # 执行同步
    try:
        sync_manager.sync_all_pending()
    except KeyboardInterrupt:
        logging.info("用户中断同步")
    except Exception as e:
        logging.error(f"同步过程出错: {e}")
    
    logging.info("=== 云端同步服务结束 ===")

if __name__ == '__main__':
    main()
