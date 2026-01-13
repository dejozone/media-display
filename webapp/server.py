#!/usr/bin/env python3
"""
Static file server for the webapp - supports both development and production (gunicorn)
"""

import http.server
import socketserver
import os
import sys
import signal
import threading
import socket
import json
from typing import Dict, Any
from dotenv import load_dotenv
from flask import Flask, send_from_directory, send_file, request
from flask_cors import CORS

# Get the directory of this file
_current_dir = os.path.dirname(os.path.abspath(__file__))

# Load environment variables from webapp/.env
_env_path = os.path.join(_current_dir, '.env')
load_dotenv(_env_path)

# Get environment name and use it to load corresponding config file
_env = os.getenv('ENV', 'dev').lower()
_config_file = f'{_env}.json'
_config_path = os.path.join(_current_dir, 'conf', _config_file)

try:
    with open(_config_path, 'r') as f:
        _json_config: Dict[str, Any] = json.load(f)
except FileNotFoundError:
    raise FileNotFoundError(f"Configuration file not found: {_config_path}")
except json.JSONDecodeError as e:
    raise ValueError(f"Invalid JSON in configuration file {_config_path}: {e}")

# Configuration
PORT = _json_config.get('server', {}).get('port', 8080)
WEBAPP_SEND_FILE_MAX_AGE_DEFAULT = _json_config.get('server', {}).get('sendFileCacheMaxAge', 86400)
WEBAPP_DIR_LISTING_MAX_AGE_DEFAULT = _json_config.get('server', {}).get('dirListingCacheMaxAge', 3600)
WEBAPP_DIR = _current_dir

# Utility function to get local IP addresses
def get_local_ip():
    """Get the local IP address(es) of the server"""
    ips = ['localhost', '127.0.0.1']
    try:
        # Get hostname
        hostname = socket.gethostname()
        # Get all IP addresses associated with hostname
        ip_addresses = socket.getaddrinfo(hostname, None, socket.AF_INET)
        for ip_info in ip_addresses:
            ip = str(ip_info[4][0])  # Ensure it's a string
            if ip not in ips and not ip.startswith('127.'):
                ips.append(ip)
    except Exception:
        pass
    
    # Try alternative method using UDP socket (doesn't actually send data)
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))  # Google DNS, connection not actually made
        local_ip = s.getsockname()[0]
        s.close()
        if local_ip not in ips:
            ips.append(local_ip)
    except Exception:
        pass
    
    return ips

# Flask app for production (gunicorn)
app = Flask(__name__, static_folder='.', static_url_path='')
app.config['WEBAPP_SEND_FILE_MAX_AGE_DEFAULT'] = WEBAPP_SEND_FILE_MAX_AGE_DEFAULT
app.config['WEBAPP_DIR_LISTING_MAX_AGE_DEFAULT'] = WEBAPP_DIR_LISTING_MAX_AGE_DEFAULT
CORS(app)

@app.route('/')
def index():
    """Serve index.html"""
    return send_file('index.html')

@app.route('/assets/images/screensavers/')
@app.route('/assets/images/screensavers')
def list_screensavers():
    """List screensaver images in nginx-style HTML format"""
    screensaver_dir = os.path.join(WEBAPP_DIR, 'assets', 'images', 'screensavers')
    
    if not os.path.exists(screensaver_dir):
        return "<html><body><h1>404 Not Found</h1></body></html>", 404
    
    try:
        from datetime import datetime
        
        files = []
        for filename in os.listdir(screensaver_dir):
            filepath = os.path.join(screensaver_dir, filename)
            if os.path.isfile(filepath):
                # Only include common image extensions
                if filename.lower().endswith(('.jpg', '.jpeg', '.png', '.gif', '.webp', '.svg')):
                    # Get file size and modification time
                    stat = os.stat(filepath)
                    size = stat.st_size
                    mtime = datetime.fromtimestamp(stat.st_mtime)
                    
                    # Format size (B, K, M)
                    if size < 1024:
                        size_str = f"{size}"
                    elif size < 1024 * 1024:
                        size_str = f"{size // 1024}K"
                    else:
                        size_str = f"{size // (1024 * 1024)}M"
                    
                    files.append({
                        'name': filename,
                        'size': size_str,
                        'mtime': mtime.strftime('%d-%b-%Y %H:%M')
                    })
        
        files.sort(key=lambda x: x['name'])
        
        # Build HTML response
        html = '<html>\n'
        html += '<head><title>Index of /assets/images/screensavers/</title></head>\n'
        html += '<body>\n'
        html += '<h1>Index of /assets/images/screensavers/</h1><hr><pre><a href="../">../</a>\n'
        
        for file_info in files:
            # Format: <a href="filename">filename</a> spaces date spaces size
            name = file_info['name']
            padded_name = name.ljust(50)
            html += f'<a href="{name}">{name}</a>{"" * (50 - len(name))}{file_info["mtime"]}  {file_info["size"].rjust(6)}\n'
        
        html += '</pre><hr></body>\n'
        html += '</html>\n'
        
        return html, 200, {'Content-Type': 'text/html; charset=utf-8'}
    except Exception as e:
        return f"<html><body><h1>Error: {str(e)}</h1></body></html>", 500

@app.route('/<path:path>')
def serve_static(path):
    """Serve static files or directory listings"""
    # Resolve path relative to webapp directory
    full_path = os.path.join(WEBAPP_DIR, path)
    
    # Check if it's a directory
    if os.path.isdir(full_path):
        # Only allow directory listing for screensavers path
        normalized_path = path.rstrip('/')
        if normalized_path == 'assets/images/screensavers':
            # Return nginx-style HTML directory listing
            try:
                from datetime import datetime
                
                files = []
                for filename in os.listdir(full_path):
                    filepath = os.path.join(full_path, filename)
                    if os.path.isfile(filepath):
                        # Get file size and modification time
                        stat = os.stat(filepath)
                        size = stat.st_size
                        mtime = datetime.fromtimestamp(stat.st_mtime)
                        
                        # Format size (B, K, M)
                        if size < 1024:
                            size_str = f"{size}"
                        elif size < 1024 * 1024:
                            size_str = f"{size // 1024}K"
                        else:
                            size_str = f"{size // (1024 * 1024)}M"
                        
                        files.append({
                            'name': filename,
                            'size': size_str,
                            'mtime': mtime.strftime('%d-%b-%Y %H:%M')
                        })
                
                files.sort(key=lambda x: x['name'])
                
                # Build HTML response
                html = '<html>\n'
                html += f'<head><title>Index of /{normalized_path}/</title></head>\n'
                html += '<body>\n'
                html += f'<h1>Index of /{normalized_path}/</h1><hr><pre><a href="../">../</a>\n'
                
                for file_info in files:
                    name = file_info['name']
                    padded_name = name.ljust(50)
                    html += f'<a href="{name}">{name}</a>{" " * (50 - len(name))}{file_info["mtime"]}  {file_info["size"].rjust(6)}\n'
                
                html += '</pre><hr></body>\n'
                html += '</html>\n'
                
                return html, 200, {'Content-Type': 'text/html; charset=utf-8'}
            except Exception as e:
                return f"<html><body><h1>Error: {str(e)}</h1></body></html>", 500
        else:
            # Directory listing not allowed for other paths
            return "Forbidden", 403
    
    # If it's a file, serve it
    if os.path.isfile(full_path):
        return send_from_directory(WEBAPP_DIR, path)
    
    # If neither file nor directory found, return 404
    return "File not found", 404

@app.after_request
def add_headers(response):
    """Add cache headers to responses"""
    if '/assets/images/screensavers/' in request.path:
        if request.path.endswith('/'):
            # Directory listing - cache using configured value
            response.headers['Cache-Control'] = f'public, max-age={app.config["WEBAPP_DIR_LISTING_MAX_AGE_DEFAULT"]}'
        else:
            # Individual image - cache using configured value
            response.headers['Cache-Control'] = f'public, max-age={app.config["WEBAPP_SEND_FILE_MAX_AGE_DEFAULT"]}, immutable'
    elif '/assets/' in request.path:
        # Other assets - cache using configured value
        response.headers['Cache-Control'] = f'public, max-age={app.config["WEBAPP_SEND_FILE_MAX_AGE_DEFAULT"]}'
    elif request.path.endswith('.html') or request.path == '/':
        # HTML pages - no cache for development
        response.headers['Cache-Control'] = 'no-store, no-cache, must-revalidate'
    
    return response

class CORSHTTPRequestHandler(http.server.SimpleHTTPRequestHandler):
    """HTTP request handler with CORS support"""
    
    def end_headers(self):
        # Add CORS headers
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        
        # Set proper cache headers for assets
        if '/assets/images/screensavers/' in self.path:
            if self.path.endswith('/'):
                # Directory listing - cache for 1 hour
                self.send_header('Cache-Control', 'public, max-age=3600')
            else:
                # Individual image - cache for 1 day
                self.send_header('Cache-Control', 'public, max-age=86400, immutable')
        elif '/assets/' in self.path:
            # Other assets - cache for 1 day
            self.send_header('Cache-Control', 'public, max-age=86400')
        else:
            # HTML pages - no cache for development
            self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate')
        
        super().end_headers()
    
    def do_OPTIONS(self):
        self.send_response(200)
        self.end_headers()
    
    def log_message(self, format, *args):
        # Custom log format
        sys.stdout.write("%s - [%s] %s\n" %
                        (self.address_string(),
                         self.log_date_time_string(),
                         format % args))

def main():
    # Change to webapp directory
    os.chdir(WEBAPP_DIR)
    
    print("=" * 60)
    print("Spotify Display Web App - Development Server")
    print("=" * 60)
    print(f"\nServing files from: {WEBAPP_DIR}")
    print(f"Server running on port: {PORT}")
    print("\nOpen in your browser:")
    
    # Show all accessible endpoints
    local_ips = get_local_ip()
    for ip in local_ips:
        print(f"  http://{ip}:{PORT}/")
    
    print("\nPress Ctrl+C to stop the server\n")
    
    # Create server with socket reuse enabled
    socketserver.TCPServer.allow_reuse_address = True
    httpd = socketserver.TCPServer(("", PORT), CORSHTTPRequestHandler)
    
    # Run server in a separate thread
    server_thread = threading.Thread(target=httpd.serve_forever)
    server_thread.daemon = True
    server_thread.start()
    
    # Signal handler for graceful shutdown
    def signal_handler(sig, frame):
        print("\n\nReceived shutdown signal, stopping server...")
        httpd.shutdown()
        httpd.server_close()
        print("Server stopped gracefully")
        sys.exit(0)
    
    # Register signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    try:
        # Keep main thread alive
        server_thread.join()
    except KeyboardInterrupt:
        print("\n\nShutting down server...")
        httpd.shutdown()
        httpd.server_close()
        print("Server stopped gracefully")
    
    return 0

if __name__ == "__main__":
    exit(main())
