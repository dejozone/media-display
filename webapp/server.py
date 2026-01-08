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
from dotenv import load_dotenv
from flask import Flask, send_from_directory, send_file, request
from flask_cors import CORS
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

# 
# Load environment variables
load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '.env'))

# Configuration
PORT = int(os.getenv('WEBAPP_PORT', '8080'))
WEBAPP_DIR = os.path.dirname(os.path.abspath(__file__))

# Flask app for production (gunicorn)
app = Flask(__name__, static_folder='.', static_url_path='')
app.config['SEND_FILE_MAX_AGE_DEFAULT'] = 86400  # Cache static files for 1 day
CORS(app)

@app.route('/')
def index():
    """Serve index.html"""
    return send_file('index.html')

@app.route('/<path:path>')
def serve_static(path):
    """Serve static files"""
    if os.path.isfile(path):
        return send_from_directory('.', path)
    # If file not found, return 404
    return "File not found", 404

@app.after_request
def add_headers(response):
    """Add cache headers to responses"""
    if '/assets/images/screensavers/' in request.path:
        if request.path.endswith('/'):
            # Directory listing - cache for 1 hour
            response.headers['Cache-Control'] = 'public, max-age=3600'
        else:
            # Individual image - cache for 1 day
            response.headers['Cache-Control'] = 'public, max-age=86400, immutable'
    elif '/assets/' in request.path:
        # Other assets - cache for 1 day
        response.headers['Cache-Control'] = 'public, max-age=86400'
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
