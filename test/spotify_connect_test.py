#!/usr/bin/env python3
"""
Test script to discover Spotify Connect devices and monitor real-time playback.
This uses mDNS/Zeroconf to discover local Spotify Connect devices and 
Spotify Web API to get current playback information.
"""

import time
import socket
from zeroconf import ServiceBrowser, Zeroconf, ServiceStateChange
import spotipy
from spotipy.oauth2 import SpotifyOAuth
import os
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import threading
import webbrowser

# Callback handling
callback_code = None
callback_received = threading.Event()

class OAuth2CallbackHandler(BaseHTTPRequestHandler):
    """Handle the OAuth2 callback"""
    def do_GET(self):
        global callback_code
        
        print(f"[SERVER] Received request: {self.path}")
        
        # Parse query parameters
        query = urlparse(self.path).query
        params = parse_qs(query)
        
        if 'code' in params:
            callback_code = params['code'][0]
            callback_received.set()
            print("[SERVER] Authorization code received!")
            
            # Send success page
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            html = """
            <html>
            <head><title>Success</title></head>
            <body style="font-family: Arial; text-align: center; padding: 50px;">
                <h1 style="color: #1DB954;">Authorization Successful!</h1>
                <p>You can close this window and return to the terminal.</p>
            </body>
            </html>
            """
            self.wfile.write(html.encode())
        elif self.path == '/':
            # Health check endpoint
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
    """Custom Spotify OAuth handler with persistent callback server"""
    def __init__(self, client_id, client_secret, redirect_uri, scope, local_port=None):
        self.client_id = client_id
        self.client_secret = client_secret
        self.redirect_uri = redirect_uri
        self.scope = scope
        self.cache_path = '.spotify_cache'
        self.server = None
        self.server_thread = None
        # Use local_port if specified, otherwise parse from redirect_uri
        self.local_port = local_port if local_port else int(redirect_uri.split(':')[-1].split('/')[0])
        
    def start_server(self):
        """Start the callback server"""
        try:
            port = self.local_port
            print(f"[DEBUG] Starting callback server on localhost:{port}...")
            
            self.server = HTTPServer(('localhost', port), OAuth2CallbackHandler)
            self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
            self.server_thread.start()
            
            # Give server a moment to start
            time.sleep(0.5)
            
            # Verify server is running
            import urllib.request
            try:
                response = urllib.request.urlopen(f'http://localhost:{port}/', timeout=2)
                print(f"✓ Callback server is running on http://localhost:{port}/")
            except Exception as e:
                print(f"⚠️  Warning: Server may not be responding: {e}")
                
        except OSError as e:
            print(f"✗ Error starting server: {e}")
            if 'Address already in use' in str(e):
                print(f"  Port {port} is already in use. Kill existing process or use different port.")
            raise
        
    def get_spotify_client(self):
        """Get authenticated Spotify client"""
        # Start the callback server first
        self.start_server()
        
        # Create auth manager
        auth_manager = SpotifyOAuth(
            client_id=self.client_id,
            client_secret=self.client_secret,
            redirect_uri=self.redirect_uri,
            scope=self.scope,
            cache_path=self.cache_path,
            open_browser=False  # We'll handle browser opening
        )
        
        # Check if we have a cached token
        token_info = auth_manager.get_cached_token()
        
        if not token_info:
            # Need to authorize
            auth_url = auth_manager.get_authorize_url()
            print(f"\nOpening browser for authorization...")
            print(f"If browser doesn't open, go to: {auth_url}\n")
            webbrowser.open(auth_url)
            
            # Wait for callback (with timeout)
            print("Waiting for authorization callback...")
            callback_received.wait(timeout=120)
            
            if callback_code:
                # Exchange code for token
                token_info = auth_manager.get_access_token(callback_code, as_dict=True, check_cache=False)
            else:
                raise Exception("Authorization timeout or failed")
        
        return spotipy.Spotify(auth_manager=auth_manager)
    
    def shutdown_server(self):
        """Stop the callback server"""
        if self.server:
            self.server.shutdown()

class SpotifyConnectMonitor:
    def __init__(self, spotify_client):
        self.devices = {}
        self.last_track_id = None
        self.sp = spotify_client
        
    def on_service_state_change(self, zeroconf, service_type, name, state_change):
        """Callback when Spotify Connect device is discovered/removed"""
        if state_change is ServiceStateChange.Added:
            info = zeroconf.get_service_info(service_type, name)
            if info:
                addresses = [socket.inet_ntoa(addr) for addr in info.addresses]
                self.devices[name] = {
                    'name': name,
                    'addresses': addresses,
                    'port': info.port,
                    'properties': info.properties
                }
                print(f"\n✓ Found Spotify Connect device: {name}")
                print(f"  Address: {addresses[0]}")
                print(f"  Port: {info.port}")
                
        elif state_change is ServiceStateChange.Removed:
            if name in self.devices:
                print(f"\n✗ Device removed: {name}")
                del self.devices[name]
    
    def get_current_playback(self):
        """Get current playback from Spotify API"""
        try:
            current = self.sp.current_playback()
            return current
        except Exception as e:
            print(f"Error getting playback: {e}")
            return None
    
    def monitor_playback(self):
        """Monitor and display current playback in real-time"""
        print("\n" + "="*60)
        print("Monitoring Spotify playback (Press Ctrl+C to stop)...")
        print("="*60 + "\n")
        
        while True:
            try:
                current = self.get_current_playback()
                
                if current and current.get('item'):
                    track = current['item']
                    track_id = track['id']
                    
                    # Only display if track changed
                    if track_id != self.last_track_id:
                        self.last_track_id = track_id
                        
                        # Extract song information
                        track_name = track['name']
                        artists = ', '.join([artist['name'] for artist in track['artists']])
                        album_name = track['album']['name']
                        album_art_url = track['album']['images'][0]['url'] if track['album']['images'] else 'N/A'
                        device_name = current.get('device', {}).get('name', 'Unknown')
                        device_type = current.get('device', {}).get('type', 'Unknown')
                        is_playing = current['is_playing']
                        
                        # Display update
                        print(f"\n{'🎵' if is_playing else '⏸️'} NOW PLAYING:")
                        print(f"  Track:  {track_name}")
                        print(f"  Artist: {artists}")
                        print(f"  Album:  {album_name}")
                        print(f"  Device: {device_name} ({device_type})")
                        print(f"  Album Art: {album_art_url}")
                        print(f"  Status: {'Playing' if is_playing else 'Paused'}")
                        print(f"  Time: {time.strftime('%H:%M:%S')}")
                        print("-" * 60)
                
                elif current:
                    if self.last_track_id is not None:
                        print(f"\n⏹️  No track currently playing")
                        self.last_track_id = None
                
                # Check every 2 seconds
                time.sleep(2)
                
            except KeyboardInterrupt:
                print("\n\nStopping monitor...")
                break
            except Exception as e:
                print(f"Error: {e}")
                time.sleep(5)

def main():
    print("Spotify Connect Real-Time Monitor")
    print("=" * 60)
    
    # Check for credentials
    client_id = os.getenv('SPOTIFY_CLIENT_ID', 'YOUR_CLIENT_ID')
    client_secret = os.getenv('SPOTIFY_CLIENT_SECRET', 'YOUR_CLIENT_SECRET')
    redirect_uri = os.getenv('SPOTIFY_REDIRECT_URI', 'http://localhost:8888/callback')
    
    if not client_id or client_id == 'YOUR_CLIENT_ID':
        print("\n⚠️  WARNING: Spotify credentials not configured!")
        print("\nPlease set the following environment variables:")
        print("  export SPOTIFY_CLIENT_ID='your_client_id'")
        print("  export SPOTIFY_CLIENT_SECRET='your_client_secret'")
        print("  export SPOTIFY_REDIRECT_URI='https://yourdomain.com:9080/callback'  # Port is parsed from this URI")
        print("\nOr edit this script and replace YOUR_CLIENT_ID and YOUR_CLIENT_SECRET")
        print("\nGet credentials at: https://developer.spotify.com/dashboard")
        print("=" * 60)
        return
    
    # Initialize auth with callback server
    auth = SpotifyAuthWithServer(
        client_id=client_id,
        client_secret=client_secret,
        redirect_uri=redirect_uri,
        scope='user-read-currently-playing user-read-playback-state'
    )
    
    print("\nInitializing Spotify authentication...")
    try:
        sp = auth.get_spotify_client()
        print("✓ Authentication successful!\n")
    except Exception as e:
        print(f"✗ Authentication failed: {e}")
        auth.shutdown_server()
        return
    
    monitor = SpotifyConnectMonitor(sp)
    
    # Start mDNS discovery for Spotify Connect devices
    print("\nDiscovering Spotify Connect devices on local network...")
    zeroconf = Zeroconf()
    browser = ServiceBrowser(
        zeroconf, 
        "_spotify-connect._tcp.local.",
        handlers=[monitor.on_service_state_change]
    )
    
    # Give it a moment to discover devices
    time.sleep(3)
    
    if monitor.devices:
        print(f"\n✓ Found {len(monitor.devices)} Spotify Connect device(s)")
    else:
        print("\n⚠️  No Spotify Connect devices found on local network")
        print("   This is normal if no devices are currently active")
    
    try:
        # Start monitoring playback
        monitor.monitor_playback()
    finally:
        print("\nCleaning up...")
        zeroconf.close()
        auth.shutdown_server()
        print("Done!")

if __name__ == "__main__":
    main()
