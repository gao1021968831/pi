#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
树莓派数据收集Flask服务器
支持手机扫码离线提交数据，自动存储到本地SQLite数据库
"""

from flask import Flask, request, render_template, jsonify, send_from_directory
import sqlite3
import json
import os
from datetime import datetime
import logging
from werkzeug.utils import secure_filename
import qrcode
from io import BytesIO
import base64

app = Flask(__name__)
app.config['SECRET_KEY'] = 'raspberry-pi-data-collector-2024'
app.config['MAX_CONTENT_LENGTH'] = 16 * 1024 * 1024  # 16MB max file size

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('flask_server.log'),
        logging.StreamHandler()
    ]
)

# 数据存储路径
DATA_DIR = '/home/pi/data'
SUBMISSIONS_DIR = os.path.join(DATA_DIR, 'submissions')
UPLOADS_DIR = os.path.join(DATA_DIR, 'uploads')
DB_PATH = os.path.join(DATA_DIR, 'submissions.db')

# 确保目录存在
for directory in [DATA_DIR, SUBMISSIONS_DIR, UPLOADS_DIR, os.path.join(DATA_DIR, 'logs')]:
    os.makedirs(directory, exist_ok=True)

def init_database():
    """初始化数据库"""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    
    # 创建数据提交表
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS submissions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            form_type VARCHAR(50),
            data TEXT,
            files TEXT,
            ip_address VARCHAR(45),
            user_agent TEXT,
            synced_to_cloud BOOLEAN DEFAULT FALSE,
            sync_timestamp DATETIME NULL
        )
    ''')
    
    # 创建系统日志表
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS system_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            level VARCHAR(20),
            message TEXT,
            source VARCHAR(50)
        )
    ''')
    
    conn.commit()
    conn.close()
    logging.info("数据库初始化完成")

def save_submission(form_type, data, files=None, ip_address=None, user_agent=None):
    """保存提交的数据到数据库"""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    
    # 处理文件信息
    file_info = []
    if files:
        for file in files:
            if file.filename:
                filename = secure_filename(file.filename)
                timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
                safe_filename = f"{timestamp}_{filename}"
                file_path = os.path.join(UPLOADS_DIR, safe_filename)
                file.save(file_path)
                file_info.append({
                    'original_name': filename,
                    'saved_name': safe_filename,
                    'path': file_path,
                    'size': os.path.getsize(file_path)
                })
    
    cursor.execute('''
        INSERT INTO submissions (form_type, data, files, ip_address, user_agent)
        VALUES (?, ?, ?, ?, ?)
    ''', (
        form_type,
        json.dumps(data, ensure_ascii=False),
        json.dumps(file_info, ensure_ascii=False) if file_info else None,
        ip_address,
        user_agent
    ))
    
    submission_id = cursor.lastrowid
    conn.commit()
    conn.close()
    
    logging.info(f"数据提交成功，ID: {submission_id}")
    return submission_id

@app.route('/')
def index():
    """主页 - 显示数据提交表单和二维码"""
    return render_template('index.html')

@app.route('/form/<form_type>')
def show_form(form_type):
    """显示特定类型的表单"""
    return render_template('form.html', form_type=form_type)

@app.route('/api/submit', methods=['POST'])
def submit_data():
    """API接口 - 接收数据提交"""
    try:
        form_type = request.form.get('form_type', 'general')
        
        # 获取表单数据
        form_data = {}
        for key, value in request.form.items():
            if key != 'form_type':
                form_data[key] = value
        
        # 获取上传的文件
        files = []
        for key, file in request.files.items():
            if file.filename:
                files.append(file)
        
        # 保存到数据库
        submission_id = save_submission(
            form_type=form_type,
            data=form_data,
            files=files if files else None,
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        
        return jsonify({
            'success': True,
            'message': '数据提交成功',
            'submission_id': submission_id,
            'timestamp': datetime.now().isoformat()
        })
        
    except Exception as e:
        logging.error(f"数据提交失败: {str(e)}")
        return jsonify({
            'success': False,
            'message': f'提交失败: {str(e)}'
        }), 500

@app.route('/api/submissions')
def get_submissions():
    """获取所有提交的数据"""
    try:
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()
        
        cursor.execute('''
            SELECT id, timestamp, form_type, data, files, ip_address, synced_to_cloud
            FROM submissions 
            ORDER BY timestamp DESC
        ''')
        
        submissions = []
        for row in cursor.fetchall():
            submission = {
                'id': row[0],
                'timestamp': row[1],
                'form_type': row[2],
                'data': json.loads(row[3]) if row[3] else {},
                'files': json.loads(row[4]) if row[4] else [],
                'ip_address': row[5],
                'synced_to_cloud': bool(row[6])
            }
            submissions.append(submission)
        
        conn.close()
        
        return jsonify({
            'success': True,
            'submissions': submissions,
            'total': len(submissions)
        })
        
    except Exception as e:
        logging.error(f"获取数据失败: {str(e)}")
        return jsonify({
            'success': False,
            'message': f'获取数据失败: {str(e)}'
        }), 500

@app.route('/api/qrcode')
def generate_qrcode():
    """生成访问二维码"""
    try:
        # 获取树莓派的IP地址
        import socket
        hostname = socket.gethostname()
        local_ip = socket.gethostbyname(hostname)
        
        # 生成访问URL
        url = f"http://192.168.150.24:5000"
        
        # 生成二维码
        qr = qrcode.QRCode(version=1, box_size=10, border=5)
        qr.add_data(url)
        qr.make(fit=True)
        
        img = qr.make_image(fill_color="black", back_color="white")
        
        # 转换为base64
        buffer = BytesIO()
        img.save(buffer, format='PNG')
        img_str = base64.b64encode(buffer.getvalue()).decode()
        
        return jsonify({
            'success': True,
            'qrcode': f"data:image/png;base64,{img_str}",
            'url': url
        })
        
    except Exception as e:
        logging.error(f"生成二维码失败: {str(e)}")
        return jsonify({
            'success': False,
            'message': f'生成二维码失败: {str(e)}'
        }), 500

@app.route('/uploads/<filename>')
def uploaded_file(filename):
    """提供上传文件的访问"""
    return send_from_directory(UPLOADS_DIR, filename)

@app.route('/admin')
def admin_panel():
    """管理面板"""
    return render_template('admin.html')

@app.route('/api/stats')
def get_stats():
    """获取系统统计信息"""
    try:
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()
        
        # 总提交数
        cursor.execute('SELECT COUNT(*) FROM submissions')
        total_submissions = cursor.fetchone()[0]
        
        # 今日提交数
        cursor.execute('''
            SELECT COUNT(*) FROM submissions 
            WHERE DATE(timestamp) = DATE('now')
        ''')
        today_submissions = cursor.fetchone()[0]
        
        # 未同步数
        cursor.execute('SELECT COUNT(*) FROM submissions WHERE synced_to_cloud = FALSE')
        unsynced_count = cursor.fetchone()[0]
        
        # 按类型统计
        cursor.execute('''
            SELECT form_type, COUNT(*) 
            FROM submissions 
            GROUP BY form_type
        ''')
        type_stats = dict(cursor.fetchall())
        
        conn.close()
        
        return jsonify({
            'success': True,
            'stats': {
                'total_submissions': total_submissions,
                'today_submissions': today_submissions,
                'unsynced_count': unsynced_count,
                'type_stats': type_stats
            }
        })
        
    except Exception as e:
        logging.error(f"获取统计信息失败: {str(e)}")
        return jsonify({
            'success': False,
            'message': f'获取统计信息失败: {str(e)}'
        }), 500

if __name__ == '__main__':
    init_database()
    app.run(host='0.0.0.0', port=5000, debug=False)
