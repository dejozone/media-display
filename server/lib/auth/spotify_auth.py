"""
Spotify Authentication
OAuth2 handler with callback server for Spotify authentication
"""
import os
import ssl
import time
import threading
import webbrowser
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from typing import Optional

import requests
import spotipy
from spotipy.oauth2 import SpotifyOAuth

from config import Config


# Global state for OAuth callback
callback_code: Optional[str] = None
callback_received = threading.Event()
oauth_callback_server: Optional[HTTPServer] = None
oauth_callback_server_lock = threading.Lock()


class OAuth2CallbackHandler(BaseHTTPRequestHandler):
    """Handle the OAuth2 callback"""
    
    def do_GET(self):
        global callback_code
        
        query = urlparse(self.path).query
        params = parse_qs(query)
        
        if 'code' in params:
            callback_code = params['code'][0]
            callback_received.set()
            
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            html = """
            <html>
            <head><title>Success</title></head>
            <body style="font-family: Arial; text-align: center; padding: 50px;">
                <h1 style="color: #1DB954;">Authorization Successful!</h1>
                <p>You can close this window. The server is now running.</p>
            </body>
            </html>
            """
            self.wfile.write(html.encode())
        elif self.path == '/':
            self.send_response(200)
            self.send_header('Content-type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'Spotify OAuth callback server is running!')
        else:
            self.send_response(400)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            self.wfile.write(b'<html><body><h1>Error: No authorization code received</h1></body></html>')
    
    def log_message(self, format, *args):
        pass  # Suppress logs


class SpotifyAuthWithServer:
    """Spotify OAuth handler with callback server"""
    
    def __init__(self, client_id: str, client_secret: str, redirect_uri: str, scope: str, local_port: Optional[int] = None):
        self.client_id = client_id
        self.client_secret = client_secret
        self.redirect_uri = redirect_uri
        self.scope = scope
        self.cache_path = Config.SPOTIFY_CACHE_PATH
        self.server: Optional[HTTPServer] = None
        self.server_thread: Optional[threading.Thread] = None
        
        # Parse port from redirect_uri if not explicitly provided
        if local_port:
            self.local_port = local_port
        else:
            # Use urlparse to properly extract port from URI
            parsed = urlparse(redirect_uri)
            # Use explicit port if present, otherwise default based on scheme
            if parsed.port:
                self.local_port = parsed.port
            else:
                # Default ports: 80 for http, 443 for https
                self.local_port = 443 if parsed.scheme == 'https' else 80
        
    def start_server(self):
        """Start the callback server (reuses existing if already running)"""
        global oauth_callback_server, oauth_callback_server_lock
        
        with oauth_callback_server_lock:
            # Check if server is already running
            if oauth_callback_server is not None:
                self.server = oauth_callback_server
                print(f"✓ Reusing existing OAuth callback server on port {self.local_port}")
                return
            
            try:
                port = self.local_port
                print(f"Starting OAuth callback server on localhost:{port}...")
                
                self.server = HTTPServer(('localhost', port), OAuth2CallbackHandler)
                
                # Enable SSL with self-signed certificate
                cert_file = os.path.join(Config.CERT_DIR, 'localhost.crt')
                key_file = os.path.join(Config.CERT_DIR, 'localhost.key')
                
                if os.path.exists(cert_file) and os.path.exists(key_file):
                    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                    context.load_cert_chain(cert_file, key_file)
                    self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
                    protocol = 'https'
                    print(f"✓ SSL enabled for OAuth callback server")
                else:
                    protocol = 'http'
                    print(f"⚠️  SSL certificates not found, using HTTP")
                
                self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
                self.server_thread.start()
                time.sleep(0.5)
                print(f"✓ OAuth callback server running on {protocol}://localhost:{port}/")
                
                # Store globally so it can be reused
                oauth_callback_server = self.server
                    
            except OSError as e:
                # If server already exists globally but we hit this, reuse it
                if oauth_callback_server is not None:
                    self.server = oauth_callback_server
                    print(f"✓ Reusing existing OAuth callback server")
                else:
                    print(f"✗ Error starting callback server: {e}")
                    if 'Address already in use' in str(e):
                        print(f"  Port {port} is already in use.")
                    raise
        
    def get_spotify_client(self):
        """Get authenticated Spotify client"""
        global callback_code, callback_received
        
        self.start_server()
        
        # Create a custom requests session with SSL verification setting
        session = requests.Session()
        session.verify = Config.SSL_VERIFY_SPOTIFY
        
        auth_manager = SpotifyOAuth(
            client_id=self.client_id,
            client_secret=self.client_secret,
            redirect_uri=self.redirect_uri,
            scope=self.scope,
            cache_path=self.cache_path,
            open_browser=False,
            requests_session=session  # type: ignore
        )
        
        token_info = auth_manager.get_cached_token()
        
        if not token_info:
            auth_url = auth_manager.get_authorize_url()
            print(f"\nAuthorization required. Opening browser...")
            print(f"If browser doesn't open, go to: {auth_url}\n")
            webbrowser.open(auth_url)
            
            print("Waiting for authorization callback...")
            callback_received.wait(timeout=120)
            
            if callback_code:
                token_info = auth_manager.get_access_token(callback_code, as_dict=False, check_cache=False)
            else:
                raise Exception("Authorization timeout or failed")
        
        # Pass the same session to Spotify client for API calls
        return spotipy.Spotify(auth_manager=auth_manager, requests_session=session)  # type: ignore
    
    def shutdown_server(self):
        """Stop the callback server (only if we own it)"""
        # Don't shutdown the shared server
        # It will be cleaned up on process exit
        pass
