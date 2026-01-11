#!/usr/bin/env python3
"""
Spotify Now Playing Server
A production-grade server that monitors Spotify playback and broadcasts
updates to connected web clients via WebSocket.
"""

import os
import time
import threading
import logging
import ssl
import socket
from flask import Flask, jsonify, send_from_directory, Response, request
from flask_socketio import SocketIO, emit
from flask_cors import CORS
import spotipy
from spotipy.oauth2 import SpotifyOAuth
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import webbrowser
from dotenv import load_dotenv
import requests
import urllib3

# Try importing Sonos library
try:
    import soco
    from soco.events import event_listener
    SONOS_AVAILABLE = True
except ImportError:
    SONOS_AVAILABLE = False
    print("⚠️  Sonos library (soco) not available. Install with: pip install soco")

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

# Load environment variables
load_dotenv()

# Configure SSL verification for Spotify API
SSL_VERIFY_SPOTIFY = os.getenv('SSL_CERT_VERIFICATION_SPOTIFY', 'true').lower() == 'true'

if not SSL_VERIFY_SPOTIFY:
    print("⚠️  SSL certificate verification DISABLED for Spotify endpoints")
    print("   Applies to: api.spotify.com, accounts.spotify.com")
    print("   This should only be used in development/testing environments")
    # Suppress only the InsecureRequestWarning from urllib3
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
else:
    print("✓ SSL certificate verification ENABLED for all Spotify endpoints")

# Suppress werkzeug logging for WebSocket disconnect errors
logging.getLogger('werkzeug').setLevel(logging.ERROR)
werkzeug_logger = logging.getLogger('werkzeug')
werkzeug_logger.addFilter(lambda record: 'write() before start_response' not in str(record.getMessage()))

# Flask app setup
app = Flask(__name__)
app.config['SECRET_KEY'] = os.getenv('SECRET_KEY', 'your-secret-key-change-in-production')
app.config['SEND_FILE_MAX_AGE_DEFAULT'] = 86400  # Default cache for static files: 1 day
CORS(app)

# Configure Socket.IO with custom path for nginx subpath proxying
socketio_path = os.getenv('WEBSOCKET_PATH', '/socket.io')
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='threading', path=socketio_path)

# Override Flask-SocketIO's aggressive no-cache defaults for static assets
@app.after_request
def after_request(response):
    # Only modify cache headers for asset routes
    if '/assets/' in request.path:
        print(f"[DEBUG] Processing asset route: {request.path}")
        print(f"[DEBUG] Cache-Control before: {response.headers.get('Cache-Control', 'NOT SET')}")
        
        # Always override cache headers for assets - Flask-SocketIO sets bad defaults
        if '/screensavers/' in request.path:
            if request.path.endswith('/'):
                # Directory listing - cache for 1 hour
                response.headers['Cache-Control'] = 'public, max-age=3600'
                print(f"[DEBUG] Set Cache-Control for directory listing")
            else:
                # Individual image - cache for 1 day
                response.headers['Cache-Control'] = 'public, max-age=86400, immutable'
                print(f"[DEBUG] Set Cache-Control for image")
        else:
            # Default for other assets - cache for 1 day
            response.headers['Cache-Control'] = 'public, max-age=86400'
            print(f"[DEBUG] Set Cache-Control for other asset")
        
        # Remove conflicting headers that prevent caching
        response.headers.pop('Pragma', None)
        if 'Expires' in response.headers:
            response.headers.pop('Expires')
        
        print(f"[DEBUG] Cache-Control after: {response.headers.get('Cache-Control', 'NOT SET')}")
    return response

# Global state
callback_code = None
callback_received = threading.Event()
spotify_client = None
current_track_data = None
connected_clients = 0
active_monitors = []  # Track which monitors are running
clients_needing_progress = set()  # Track which clients need progress updates
desired_services = set()  # Services that should be active based on MEDIA_SERVICE_METHOD
recovery_thread = None  # Background thread for service recovery
recovery_running = False  # Control flag for recovery thread

# Global state for OAuth callback server
oauth_callback_server = None
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
    def __init__(self, client_id, client_secret, redirect_uri, scope, local_port=None):
        self.client_id = client_id
        self.client_secret = client_secret
        self.redirect_uri = redirect_uri
        self.scope = scope
        self.cache_path = '.spotify_cache'
        self.server = None
        self.server_thread = None
        
        # Parse port from redirect_uri if not explicitly provided
        if local_port:
            self.local_port = local_port
        else:
            # Use urlparse to properly extract port from URI
            from urllib.parse import urlparse
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
                server_dir = os.path.dirname(os.path.abspath(__file__))
                project_root = os.path.dirname(server_dir)
                cert_file = os.path.join(project_root, 'certs', 'localhost.crt')
                key_file = os.path.join(project_root, 'certs', 'localhost.key')
                
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
        self.start_server()
        
        # Create a custom requests session with SSL verification setting
        session = requests.Session()
        session.verify = SSL_VERIFY_SPOTIFY
        
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
        global oauth_callback_server, oauth_callback_server_lock
        
        # Don't shutdown the shared server
        # It will be cleaned up on process exit
        pass

class DeviceMonitor:
    """Monitor Sonos devices for playback updates"""
    
    def __init__(self):
        self.devices = []
        self.subscriptions = []
        self.is_running = False
        self.is_ready = False  # Track if monitor is fully initialized
        self.last_track_id = None
        self.last_update_time = 0
        self.source_priority = 1  # Lower number = higher priority (Sonos = 1, Spotify = 2)
        self.polling_thread = None  # Thread for polling position updates
    
    def get_device_names(self, coordinator_device):
        """Get list of device names from a group"""
        try:
            # Get all members of the group
            group = coordinator_device.group
            if group and hasattr(group, 'members'):
                # Get unique device names (in case of duplicates)
                device_names = list(set([member.player_name for member in group.members]))
                device_names.sort()  # Sort for consistent ordering
                return device_names
            else:
                return [coordinator_device.player_name]
        except Exception as e:
            print(f"  ⚠️  Error getting device names: {e}")
            return [coordinator_device.player_name]
        
    def discover_sonos_devices(self):
        """Discover Sonos speakers on network"""
        if not SONOS_AVAILABLE:
            return False
            
        print("🔍 Discovering Sonos devices...")
        try:
            devices = soco.discover(timeout=5)
            if devices:
                for device in devices:
                    print(f"  ✓ Found Sonos: {device.player_name} ({device.ip_address})")
                    self.devices.append({
                        'type': 'sonos',
                        'device': device,
                        'name': device.player_name
                    })
                return True
            else:
                print("  ℹ️  No Sonos devices found")
                return False
        except Exception as e:
            print(f"  ✗ Error discovering Sonos: {e}")
            return False
    
    def on_sonos_event(self, event):
        """Handle Sonos transport events"""
        global current_track_data
        
        try:
            # Get the parent service to access track info
            if hasattr(event.service, 'soco'):
                device = event.service.soco
                track = device.get_current_track_info()
                transport = device.get_current_transport_info()
                
                if track and track.get('title') and track.get('title') != '':
                    # Get device names list
                    device_names = self.get_device_names(device)
                    
                    # Parse duration and position (format: "H:MM:SS" or "M:SS")
                    def parse_time_to_ms(time_str):
                        """Convert H:MM:SS or M:SS to milliseconds"""
                        try:
                            if not time_str or time_str == '0:00:00':
                                return 0
                            parts = time_str.split(':')
                            if len(parts) == 3:  # H:MM:SS
                                hours, minutes, seconds = map(int, parts)
                                return (hours * 3600 + minutes * 60 + seconds) * 1000
                            elif len(parts) == 2:  # M:SS
                                minutes, seconds = map(int, parts)
                                return (minutes * 60 + seconds) * 1000
                        except:
                            return 0
                        return 0
                    
                    duration_ms = parse_time_to_ms(track.get('duration', '0:00:00'))
                    position_ms = parse_time_to_ms(track.get('position', '0:00:00'))
                    
                    track_data = {
                        'track_name': track.get('title', 'Unknown'),
                        'artist': track.get('artist', 'Unknown Artist'),
                        'album': track.get('album', 'Unknown Album'),
                        'album_art': track.get('album_art', None),
                        'is_playing': transport.get('current_transport_state') == 'PLAYING',
                        'progress_ms': position_ms,
                        'duration_ms': duration_ms,
                        'device': {
                            'names': device_names,
                            'type': 'Sonos Speaker'
                        },
                        'source': 'sonos',
                        'source_priority': self.source_priority,
                        'timestamp': time.time()
                    }
                    
                    track_id = f"{track_data['track_name']}_{track_data['artist']}"
                    current_time = time.time()
                    
                    # Only update if:
                    # 1. Track changed, OR
                    # 2. Playback state changed, OR
                    # 3. This source has higher priority (lower number) than current source
                    should_update = (
                        self.last_track_id != track_id or
                        current_track_data is None or
                        current_track_data.get('is_playing') != track_data['is_playing'] or
                        current_track_data.get('source_priority', 999) > self.source_priority
                    )
                    
                    if should_update:
                        self.last_track_id = track_id
                        self.last_update_time = current_time
                        
                        # Log when switching to Sonos as progress source
                        if current_track_data and current_track_data.get('source') != 'sonos':
                            print("📊 Progress source: SONOS (priority)")
                        
                        current_track_data = track_data
                        socketio.emit('track_update', track_data, namespace='/')
                        
                        status = '🎵' if track_data['is_playing'] else '⏸️'
                        print(f"{status} [SONOS] {track_data['track_name']} - {track_data['artist']}")
                        
        except Exception as e:
            print(f"Error handling Sonos event: {e}")
    
    def subscribe_to_devices(self):
        """Subscribe to events from all discovered devices"""
        if not self.devices:
            return False
            
        print("\n📡 Subscribing to device events...")
        
        for device_info in self.devices:
            if device_info['type'] == 'sonos':
                try:
                    device = device_info['device']
                    
                    # Subscribe to AVTransport events (play/pause/track change)
                    sub = device.avTransport.subscribe(auto_renew=True)
                    
                    # Store device name and reference for event handler
                    sub.service.device_name = device_info['name']
                    sub.service.soco = device
                    
                    # Set callback
                    sub.callback = self.on_sonos_event
                    
                    self.subscriptions.append(sub)
                    print(f"  ✓ Subscribed to {device_info['name']}")
                    
                except Exception as e:
                    print(f"  ✗ Failed to subscribe to {device_info['name']}: {e}")
        
        return len(self.subscriptions) > 0
    
    def get_initial_state(self):
        """Get current playback state from devices"""
        global current_track_data
        
        for device_info in self.devices:
            if device_info['type'] == 'sonos':
                try:
                    device = device_info['device']
                    track = device.get_current_track_info()
                    transport = device.get_current_transport_info()
                    
                    if track and track.get('title') and track.get('title') != '':
                        # Get device names list
                        device_names = self.get_device_names(device)
                        
                        # Parse duration and position (format: "H:MM:SS" or "M:SS")
                        def parse_time_to_ms(time_str):
                            """Convert H:MM:SS or M:SS to milliseconds"""
                            try:
                                if not time_str or time_str == '0:00:00':
                                    return 0
                                parts = time_str.split(':')
                                if len(parts) == 3:  # H:MM:SS
                                    hours, minutes, seconds = map(int, parts)
                                    return (hours * 3600 + minutes * 60 + seconds) * 1000
                                elif len(parts) == 2:  # M:SS
                                    minutes, seconds = map(int, parts)
                                    return (minutes * 60 + seconds) * 1000
                            except:
                                return 0
                            return 0
                        
                        duration_ms = parse_time_to_ms(track.get('duration', '0:00:00'))
                        position_ms = parse_time_to_ms(track.get('position', '0:00:00'))
                        
                        track_data = {
                            'track_name': track.get('title', 'Unknown'),
                            'artist': track.get('artist', 'Unknown Artist'),
                            'album': track.get('album', 'Unknown Album'),
                            'album_art': track.get('album_art', None),
                            'is_playing': transport.get('current_transport_state') == 'PLAYING',
                            'progress_ms': position_ms,
                            'duration_ms': duration_ms,
                            'device': {
                                'names': device_names,
                                'type': 'Sonos Speaker'
                            },
                            'source': 'sonos',
                            'source_priority': self.source_priority,
                            'timestamp': time.time()
                        }
                        current_track_data = track_data
                        self.last_track_id = f"{track_data['track_name']}_{track_data['artist']}"
                        self.last_update_time = time.time()
                        
                        # Format device names for logging
                        device_display = device_names[0] if len(device_names) == 1 else f"{device_names[0]} +{len(device_names)-1} more"
                        print(f"  ℹ️  Initial state: {track_data['track_name']} - {track_data['artist']}")
                        print(f"  📱 Playing on: {device_display}")
                        return track_data
                        
                except Exception as e:
                    print(f"  ⚠️  Error getting initial state from {device_info['name']}: {e}")
        
        return None
    
    def poll_position_updates(self):
        """Poll Sonos devices for position updates every 2 seconds"""
        global current_track_data, clients_needing_progress
        
        while self.is_running:
            try:
                time.sleep(2)  # Poll every 2 seconds
                
                # Only poll if we have Sonos as the active source AND clients need progress
                if current_track_data and current_track_data.get('source') == 'sonos' and len(clients_needing_progress) > 0:
                    for device_info in self.devices:
                        if device_info['type'] == 'sonos':
                            try:
                                device = device_info['device']
                                track = device.get_current_track_info()
                                transport = device.get_current_transport_info()
                                
                                if track and track.get('title'):
                                    # Parse position
                                    def parse_time_to_ms(time_str):
                                        try:
                                            if not time_str or time_str == '0:00:00':
                                                return 0
                                            parts = time_str.split(':')
                                            if len(parts) == 3:  # H:MM:SS
                                                hours, minutes, seconds = map(int, parts)
                                                return (hours * 3600 + minutes * 60 + seconds) * 1000
                                            elif len(parts) == 2:  # M:SS
                                                minutes, seconds = map(int, parts)
                                                return (minutes * 60 + seconds) * 1000
                                        except:
                                            return 0
                                        return 0
                                    
                                    position_ms = parse_time_to_ms(track.get('position', '0:00:00'))
                                    duration_ms = parse_time_to_ms(track.get('duration', '0:00:00'))
                                    is_playing = transport.get('current_transport_state') == 'PLAYING'
                                    
                                    # Update current_track_data with fresh position
                                    if current_track_data:
                                        current_track_data['progress_ms'] = position_ms
                                        current_track_data['duration_ms'] = duration_ms
                                        current_track_data['is_playing'] = is_playing
                                        current_track_data['timestamp'] = time.time()
                                        
                                        # Broadcast update
                                        socketio.emit('track_update', current_track_data, namespace='/')
                                    
                                    break  # Only need to poll one device
                                    
                            except Exception as e:
                                print(f"⚠️  Sonos polling error: {e}")
                                
            except Exception as e:
                print(f"⚠️  Position polling error: {e}")
    
    def start(self):
        """Start monitoring devices"""
        if not self.is_running:
            self.is_running = True
            
            # Discover devices
            has_devices = self.discover_sonos_devices()
            
            if not has_devices:
                print("\n⚠️  No Sonos devices found on network")
                self.is_running = False
                return False
            
            # Subscribe to events
            if not self.subscribe_to_devices():
                print("\n⚠️  Failed to subscribe to any devices")
                self.is_running = False
                return False
            
            # Get initial state
            self.get_initial_state()
            
            # Start position polling thread
            self.polling_thread = threading.Thread(target=self.poll_position_updates, daemon=True)
            self.polling_thread.start()
            
            self.is_ready = True
            print("\n✅ Sonos monitoring started")
            return True
        
        return False
    
    def stop(self):
        """Stop monitoring and unsubscribe"""
        self.is_running = False
        
        # Wait for polling thread to finish
        if self.polling_thread and self.polling_thread.is_alive():
            self.polling_thread.join(timeout=3)
        
        for sub in self.subscriptions:
            try:
                sub.unsubscribe()
            except:
                pass
        
        self.subscriptions.clear()
        print("Sonos monitoring stopped")

class SpotifyMonitor:
    """Monitor Spotify playback and broadcast updates"""
    def __init__(self, spotify_client):
        self.sp = spotify_client
        self.is_ready = False  # Track if monitor is fully initialized
        self.last_track_id = None
        self.last_device_name = None
        self.is_running = False
        self.monitor_thread = None
        self.last_update_time = 0
        self.source_priority = 2  # Lower number = higher priority (Sonos = 1, Spotify = 2)
        
    def get_current_playback(self):
        """Get current playback information"""
        try:
            current = self.sp.current_playback()
            if current and current.get('item'):
                track = current['item']
                return {
                    'track_id': track['id'],
                    'track_name': track['name'],
                    'artist': ', '.join([artist['name'] for artist in track['artists']]),
                    'album': track['album']['name'],
                    'album_art': track['album']['images'][0]['url'] if track['album']['images'] else None,
                    'is_playing': current['is_playing'],
                    'progress_ms': current.get('progress_ms', 0),
                    'duration_ms': track['duration_ms'],
                    'device': {
                        'name': current.get('device', {}).get('name', 'Unknown'),
                        'type': current.get('device', {}).get('type', 'Unknown')
                    },
                    'source': 'spotify',
                    'source_priority': self.source_priority,
                    'timestamp': time.time()
                }
            return None
        except Exception as e:
            print(f"Error getting playback: {e}")
            return None
    
    def monitor_loop(self):
        """Main monitoring loop"""
        global current_track_data
        print("Starting playback monitor...")
        
        while self.is_running:
            try:
                track_data = self.get_current_playback()
                current_time = time.time()
                
                if track_data:
                    track_id = track_data['track_id']
                    device_name = track_data['device']['name']
                    
                    # Create a comparable track identifier (same format as Sonos)
                    comparable_track_id = f"{track_data['track_name']}_{track_data['artist']}"
                    current_comparable_id = f"{current_track_data.get('track_name', '')}_{current_track_data.get('artist', '')}" if current_track_data else None
                    
                    # Check if we should take over or update
                    time_since_last_update = current_time - (current_track_data.get('timestamp', 0) if current_track_data else 0)
                    
                    is_same_track = (comparable_track_id == current_comparable_id)
                    has_higher_priority = (current_track_data.get('source_priority', 999) if current_track_data else 999) > self.source_priority
                    is_stale = time_since_last_update > 10
                    device_changed = device_name != self.last_device_name
                    is_our_source = current_track_data and current_track_data.get('source') == 'spotify'
                    
                    # Determine if we should update:
                    # 1. Major changes (track/device/state change) - only if we can take over
                    # 2. We're already the active source - always update position
                    # 3. We can take over (higher priority or stale source or no current source)
                    major_change = (
                        track_id != self.last_track_id or
                        device_changed or
                        current_track_data is None or
                        track_data['is_playing'] != current_track_data.get('is_playing')
                    )
                    
                    # Only allow takeover if we have higher priority OR source is stale OR no current source
                    can_take_over = (
                        has_higher_priority or 
                        is_stale or 
                        current_track_data is None
                    )
                    
                    # For progress updates: only send if clients need progress
                    needs_progress_update = is_our_source and len(clients_needing_progress) > 0
                    
                    should_update = (
                        major_change and can_take_over
                    ) or needs_progress_update
                    
                    if should_update:
                        self.last_track_id = track_id
                        self.last_device_name = device_name
                        self.last_update_time = current_time
                        
                        # Log when switching to Spotify as progress source
                        if major_change and (current_track_data is None or current_track_data.get('source') != 'spotify'):
                            print("📊 Progress source: SPOTIFY (fallback)")
                        
                        current_track_data = track_data
                        
                        try:
                            socketio.emit('track_update', track_data, namespace='/')
                        except Exception:
                            pass
                        
                        # Only log major changes, not every position update
                        if major_change:
                            print(f"{'🎵' if track_data['is_playing'] else '⏸️'} [SPOTIFY] {track_data['track_name']} - {track_data['artist']}")
                
                elif current_track_data is not None and current_track_data.get('source') == 'spotify':
                    # Only clear if current source is Spotify
                    current_track_data = None
                    self.last_track_id = None
                    self.last_device_name = None
                    try:
                        socketio.emit('track_update', None, namespace='/')
                    except Exception:
                        pass
                    print("⏹️  [SPOTIFY] No track playing")
                
                # Sleep for 2 seconds before next check
                time.sleep(2)
                
            except Exception as e:
                print(f"Error in monitor loop: {e}")
                time.sleep(5)
    
    def start(self):
        """Start monitoring in background thread"""
        if not self.is_running:
            self.is_running = True
            self.monitor_thread = threading.Thread(target=self.monitor_loop, daemon=True)
            self.is_ready = True
            self.monitor_thread.start()
            print("✓ Spotify monitor started")
    
    def stop(self):
        self.is_ready = False
        """Stop monitoring"""
        self.is_running = False
        if self.monitor_thread:
            self.monitor_thread.join(timeout=5)
        print("Spotify monitor stopped")

# WebSocket event handlers
def get_active_services():
    """Get dictionary of currently active services"""
    return {
        'sonos': any(isinstance(m, DeviceMonitor) and m.is_ready and m.is_running for m in active_monitors),
        'spotify': any(isinstance(m, SpotifyMonitor) and m.is_ready and m.is_running for m in active_monitors)
    }

def broadcast_service_status():
    """Broadcast service status to all connected clients"""
    active_services = get_active_services()
    try:
        socketio.emit('service_status', active_services, namespace='/')
    except Exception as e:
        print(f"⚠️  Error broadcasting service status: {e}")

def is_service_active(service_name):
    """Check if a specific service is currently active"""
    if service_name == 'sonos':
        return any(isinstance(m, DeviceMonitor) and m.is_ready and m.is_running for m in active_monitors)
    elif service_name == 'spotify':
        return any(isinstance(m, SpotifyMonitor) and m.is_ready and m.is_running for m in active_monitors)
    return False

def get_service_monitor(service_name):
    """Get the monitor instance for a specific service"""
    if service_name == 'sonos':
        for m in active_monitors:
            if isinstance(m, DeviceMonitor):
                return m
    elif service_name == 'spotify':
        for m in active_monitors:
            if isinstance(m, SpotifyMonitor):
                return m
    return None

@socketio.on('connect')
def handle_connect():
    global connected_clients
    connected_clients += 1
    print(f"Client connected. Total clients: {connected_clients}")
    
    # Send current service status
    active_services = get_active_services()
    emit('service_status', active_services)
    
    # Send current track immediately upon connection
    if current_track_data:
        emit('track_update', current_track_data)

@socketio.on('disconnect')
def handle_disconnect():
    global connected_clients, clients_needing_progress
    try:
        client_id = request.sid  # type: ignore
        connected_clients -= 1
        print(f"Client disconnected: {client_id[:8]}... Total clients: {connected_clients}")
        
        # Remove from progress tracking if present
        if client_id in clients_needing_progress:
            clients_needing_progress.discard(client_id)
            if len(clients_needing_progress) == 0:
                print("📊 Stopping progress tracking (no clients need it)")
    except Exception:
        # Suppress werkzeug disconnect errors
        pass

@socketio.on('request_current_track')
def handle_request_current_track():
    """Client requests current track info"""
    if current_track_data:
        emit('track_update', current_track_data)
    else:
        emit('track_update', None)

@socketio.on('enable_progress')
def handle_enable_progress():
    """Client enables progress effects and needs progress updates"""
    global clients_needing_progress
    client_id = request.sid  # type: ignore
    
    # Log which service is currently active
    current_source = current_track_data.get('source', 'none').upper() if current_track_data else 'NONE'
    print(f"📡 Received 'enable_progress' from client {client_id[:8]}... (Active source: {current_source})")
    
    if client_id not in clients_needing_progress:
        clients_needing_progress.add(client_id)
        print(f"✅ Progress updates enabled for client {client_id[:8]}... (Total: {len(clients_needing_progress)})")
        
        # If this is the first client needing progress, log the change
        if len(clients_needing_progress) == 1:
            print("📊 Starting progress tracking (client requested)")

@socketio.on('disable_progress')
def handle_disable_progress():
    """Client disables progress effects and no longer needs progress updates"""
    global clients_needing_progress
    client_id = request.sid  # type: ignore
    
    print(f"📡 Received 'disable_progress' from client {client_id[:8]}...")
    
    if client_id in clients_needing_progress:
        clients_needing_progress.discard(client_id)
        print(f"⏸️  Progress updates disabled for client {client_id[:8]}... (Total: {len(clients_needing_progress)})")
        
        # If no clients need progress anymore, log the change
        if len(clients_needing_progress) == 0:
            print("📊 Stopping progress tracking (no clients need it)")

# HTTP routes
@app.route('/')
def index():
    """Serve the main web app"""
    return """
    <!DOCTYPE html>
    <html>
    <head>
        <title>Spotify Now Playing</title>
    </head>
    <body>
        <h1>Spotify Now Playing Server</h1>
        <p>Server is running. Connect your display client via WebSocket.</p>
        <p>WebSocket endpoint: <code>ws://localhost:5000</code></p>
        <p>Connected clients: <span id="clients">0</span></p>
        
        <script src="https://cdn.socket.io/4.8.3/socket.io.min.js"></script>
        <script>
            const socket = io();
            socket.on('connect', () => {
                console.log('Connected to server');
            });
            socket.on('track_update', (data) => {
                console.log('Track update:', data);
            });
        </script>
    </body>
    </html>
    """

@app.route('/health')
def health():
    """Health check endpoint"""
    active_sources = [m.__class__.__name__ for m in active_monitors]
    return jsonify({
        'status': 'ok',
        'connected_clients': connected_clients,
        'active_monitors': active_sources,
        'current_track': current_track_data is not None,
        'current_source': current_track_data.get('source') if current_track_data else None
    })

@app.route('/assets/images/screensavers/')
def list_screensaver_images():
    """List screensaver images with directory listing"""
    # Determine the webapp assets path relative to this server file
    # Server is in server/app.py, webapp assets are in webapp/assets/
    server_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(server_dir)
    screensaver_dir = os.path.join(project_root, 'webapp', 'assets', 'images', 'screensavers')
    
    if not os.path.exists(screensaver_dir):
        return jsonify({'error': 'Directory not found'}), 404
    
    try:
        # Get list of image files
        files = []
        for filename in os.listdir(screensaver_dir):
            filepath = os.path.join(screensaver_dir, filename)
            if os.path.isfile(filepath):
                # Only include common image extensions
                if filename.lower().endswith(('.jpg', '.jpeg', '.png', '.gif', '.webp', '.svg')):
                    files.append(filename)
        
        # Sort files alphabetically
        files.sort()
        
        # Generate HTML directory listing (similar to nginx autoindex)
        html = f'''<!DOCTYPE html>
<html>
<head>
    <title>Index of /assets/images/screensavers/</title>
    <style>
        body {{ font-family: monospace; margin: 20px; }}
        h1 {{ font-size: 18px; }}
        a {{ display: block; padding: 2px 0; text-decoration: none; }}
        a:hover {{ background-color: #f0f0f0; }}
    </style>
</head>
<body>
    <h1>Index of /assets/images/screensavers/</h1>
    <hr>
    <pre>
'''
        
        for filename in files:
            html += f'<a href="{filename}">{filename}</a>\n'
        
        html += '''    </pre>
    <hr>
</body>
</html>'''
        
        response = Response(html, mimetype='text/html')
        # Add CORS headers for JavaScript access
        response.headers['Access-Control-Allow-Origin'] = '*'
        response.headers['Access-Control-Allow-Methods'] = 'GET, OPTIONS'
        response.headers['Access-Control-Allow-Headers'] = 'Content-Type'
        # Cache headers set by after_request hook
        
        return response
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/assets/images/screensavers/<filename>')
def serve_screensaver_image(filename):
    """Serve individual screensaver images"""
    server_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(server_dir)
    screensaver_dir = os.path.join(project_root, 'webapp', 'assets', 'images', 'screensavers')
    
    try:
        response = send_from_directory(screensaver_dir, filename)
        # Add CORS headers
        response.headers['Access-Control-Allow-Origin'] = '*'
        # Cache headers set by after_request hook
        return response
    except Exception as e:
        return jsonify({'error': 'File not found'}), 404

def initialize_spotify():
    """Initialize Spotify authentication and monitoring"""
    global spotify_client
    
    client_id = os.getenv('SPOTIFY_CLIENT_ID')
    client_secret = os.getenv('SPOTIFY_CLIENT_SECRET')
    redirect_uri = os.getenv('SPOTIFY_REDIRECT_URI', 'http://localhost:8888/callback')
    
    # Get LOCAL_CALLBACK_PORT if explicitly set (optional override)
    local_callback_port = os.getenv('LOCAL_CALLBACK_PORT', '').strip()
    local_port = int(local_callback_port) if local_callback_port else None
    
    if not client_id or not client_secret:
        raise Exception("SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET must be set")
    
    # Initialize auth (port from LOCAL_CALLBACK_PORT or parsed from redirect_uri)
    auth = SpotifyAuthWithServer(
        client_id=client_id,
        client_secret=client_secret,
        redirect_uri=redirect_uri,
        scope='user-read-currently-playing user-read-playback-state',
        local_port=local_port
    )
    
    # Get authenticated client
    spotify_client = auth.get_spotify_client()
    
    # Verify authentication by making a test call
    try:
        spotify_client.current_user()
        print("✓ Spotify authentication successful!\n")
    except Exception as e:
        raise Exception(f"Spotify authentication failed: {e}")
    
    # Start monitoring
    monitor = SpotifyMonitor(spotify_client)
    monitor.start()
    
    return monitor

def try_start_sonos():
    """Attempt to start Sonos monitoring, return True if successful"""
    global active_monitors
    
    if not SONOS_AVAILABLE:
        return False
    
    try:
        # Check if already active
        if is_service_active('sonos'):
            return True
        
        # Remove any old inactive Sonos monitor
        active_monitors = [m for m in active_monitors if not isinstance(m, DeviceMonitor)]
        
        # Try to start new monitor
        device_monitor = DeviceMonitor()
        if device_monitor.start():
            active_monitors.append(device_monitor)
            print("✅ Sonos service recovered and activated")
            broadcast_service_status()
            return True
        else:
            return False
    except Exception as e:
        print(f"⚠️  Sonos recovery attempt failed: {e}")
        return False

def try_start_spotify():
    """Attempt to start Spotify monitoring, return True if successful"""
    global active_monitors
    
    try:
        # Check if already active
        if is_service_active('spotify'):
            return True
        
        # Remove any old inactive Spotify monitor
        active_monitors = [m for m in active_monitors if not isinstance(m, SpotifyMonitor)]
        
        # Try to start new monitor
        monitor = initialize_spotify()
        active_monitors.append(monitor)
        print("✅ Spotify service recovered and activated")
        
        # Give monitor a moment to verify it's working
        time.sleep(2)
        
        broadcast_service_status()
        return True
    except OSError as e:
        if 'Address already in use' in str(e):
            # Callback server already exists, this likely means Spotify is initializing
            # Check again if service became active
            time.sleep(3)
            if is_service_active('spotify'):
                print("✅ Spotify service is active (callback server already running)")
                broadcast_service_status()
                return True
        print(f"⚠️  Spotify recovery attempt failed: {e}")
        return False
    except Exception as e:
        print(f"⚠️  Spotify recovery attempt failed: {e}")
        return False

def service_recovery_loop():
    """Background thread that continuously monitors and recovers failed services"""
    global recovery_running, desired_services
    
    retry_count: dict[str, int] = {'sonos': 0, 'spotify': 0}
    first_failure_time: dict[str, float | None] = {'sonos': None, 'spotify': None}
    # Get timeout from environment variable (default: 5 minutes = 300 seconds)
    max_retry_duration = int(os.getenv('SERVICE_RECOVERY_TIMEOUT_MINUTES', '5')) * 60
    timeout_minutes = max_retry_duration // 60
    
    # Give initial startup time before starting recovery checks
    print("🔄 Service recovery thread started")
    print(f"   Monitoring services: {', '.join(sorted(desired_services))}")
    print("   Waiting 15s for initial service startup...")
    time.sleep(15)
    
    while recovery_running:
        try:
            # Check each desired service
            for service in desired_services:
                if not is_service_active(service):
                    # Track first failure time
                    failure_start = first_failure_time[service]
                    if failure_start is None:
                        failure_start = time.time()
                        first_failure_time[service] = failure_start
                    
                    # Check if we've exceeded the retry window
                    elapsed_time = time.time() - failure_start
                    if elapsed_time > max_retry_duration:
                        if retry_count[service] > 0:  # Only print once
                            print(f"⏱️  {service.upper()} service recovery timeout ({timeout_minutes} minute{'s' if timeout_minutes != 1 else ''} exceeded)")
                            print(f"   Stopped retrying after {retry_count[service]} attempts")
                            retry_count[service] = -1  # Mark as timed out
                        continue  # Skip this service
                    
                    retry_count[service] += 1
                    remaining_time = int(max_retry_duration - elapsed_time)
                    print(f"🔄 Attempting to recover {service.upper()} service (attempt #{retry_count[service]}, timeout in {remaining_time}s)...")
                    
                    success = False
                    if service == 'sonos':
                        success = try_start_sonos()
                    elif service == 'spotify':
                        success = try_start_spotify()
                    
                    if success:
                        retry_count[service] = 0  # Reset counter on success
                        first_failure_time[service] = None
                    else:
                        print(f"⚠️  {service.upper()} recovery failed. Will retry in 30 seconds...")
                else:
                    # Service is active, reset retry counter and failure time
                    if retry_count[service] != 0:
                        if retry_count[service] > 0:
                            print(f"✅ {service.upper()} service is healthy again")
                        retry_count[service] = 0
                        first_failure_time[service] = None
                    
                    # Verify service is still healthy
                    monitor = get_service_monitor(service)
                    if monitor:
                        if not monitor.is_running or not monitor.is_ready:
                            print(f"⚠️  {service.upper()} service detected as unhealthy, marking for recovery...")
                            monitor.is_ready = False
                            if monitor in active_monitors:
                                active_monitors.remove(monitor)
                            broadcast_service_status()
            
            # Sleep for 30 seconds before next check (increased from 10s)
            time.sleep(30)
            
        except Exception as e:
            print(f"⚠️  Error in service recovery loop: {e}")
            time.sleep(30)
    
    print("🔄 Service recovery thread stopped")

def main():
    """Main entry point"""
    print("=" * 60)
    print("Now Playing Server (Multi-Source Monitor)")
    print("=" * 60)
    
    global active_monitors, desired_services, recovery_running, recovery_thread
    
    try:
        service_method = os.getenv('MEDIA_SERVICE_METHOD', 'all').lower().strip()
        
        if service_method not in ['sonos', 'spotify', 'all']:
            print(f"\n⚠️  Invalid MEDIA_SERVICE_METHOD: '{service_method}'")
            print("Valid options: 'sonos', 'spotify', 'all'")
            print("Defaulting to 'all'\n")
            service_method = 'all'
        
        # Set desired services based on configuration
        if service_method == 'spotify':
            desired_services = {'spotify'}
        elif service_method == 'sonos':
            desired_services = {'sonos'}
        else:  # 'all'
            desired_services = {'sonos', 'spotify'}
        
        print("\n🔧 Initializing playback monitoring...")
        print(f"Configuration: MEDIA_SERVICE_METHOD={service_method.upper()}\n")
        
        if service_method == 'spotify':
            # Spotify only
            print("=" * 60)
            print("Mode: Spotify Connect Only")
            print("=" * 60)
            
            monitor = initialize_spotify()
            active_monitors.append(monitor)
            print("\n✅ Spotify monitoring active")
            
        elif service_method == 'sonos':
            # Sonos only
            print("=" * 60)
            print("Mode: Sonos API Only")
            print("=" * 60)
            
            device_monitor = DeviceMonitor()
            if device_monitor.start():
                active_monitors.append(device_monitor)
                print("\n✅ Sonos monitoring active")
            else:
                print("\n✗ Failed to start Sonos monitoring")
                return 1
                
        else:  # service_method == 'all'
            # Monitor BOTH simultaneously
            print("=" * 60)
            # Use threading to initialize services in parallel
            sonos_result = {'started': False, 'monitor': None}
            spotify_result = {'started': False, 'monitor': None}
            
            def init_sonos():
                """Initialize Sonos in background thread"""
                print("🔵 Starting Sonos monitor...")
                try:
                    if SONOS_AVAILABLE:
                        device_monitor = DeviceMonitor()
                        if device_monitor.start():
                            sonos_result['monitor'] = device_monitor
                            sonos_result['started'] = True
                            print("✅ Sonos monitoring active")
                        else:
                            print("⚠️  Sonos monitoring unavailable (no devices found)")
                    else:
                        print("⚠️  Sonos library not installed")
                except Exception as e:
                    print(f"⚠️  Sonos initialization failed: {e}")
            
            def init_spotify():
                """Initialize Spotify in background thread"""
                print("🟢 Starting Spotify monitor...")
                try:
                    spotify_monitor = initialize_spotify()
                    spotify_result['monitor'] = spotify_monitor
                    spotify_result['started'] = True
                    print("✅ Spotify monitoring active")
                except Exception as e:
                    print(f"⚠️  Spotify monitoring unavailable: {e}")
            
            # Start both initializations in parallel
            sonos_thread = threading.Thread(target=init_sonos, daemon=True)
            spotify_thread = threading.Thread(target=init_spotify, daemon=True)
            
            sonos_thread.start()
            spotify_thread.start()
            
            # Wait for at least one to succeed, checking every second
            max_wait = 30
            for i in range(max_wait):
                time.sleep(1)
                
                # Check if at least one service has started
                if sonos_result['started'] or spotify_result['started']:
                    print(f"\n✓ At least one service ready after {i+1}s")
                    break
                    
                # If both threads have finished but neither succeeded, exit early
                if not sonos_thread.is_alive() and not spotify_thread.is_alive():
                    break
            
            # Give remaining thread a bit more time if needed, but don't block
            if sonos_thread.is_alive():
                sonos_thread.join(timeout=2)
            if spotify_thread.is_alive():
                spotify_thread.join(timeout=2)
            
            print()
            
            # Add successfully started monitors to active list
            if sonos_result['started'] and sonos_result['monitor']:
                active_monitors.append(sonos_result['monitor'])
            
            if spotify_result['started'] and spotify_result['monitor']:
                active_monitors.append(spotify_result['monitor'])
            
            # Check if at least one monitor started
            if not sonos_result['started'] and not spotify_result['started']:
                print("✗ Failed to start any monitoring service")
                return 1
            
            if sonos_result['started'] and spotify_result['started']:
                print("✅ Both Sonos and Spotify monitoring active (Sonos priority)")
            elif sonos_result['started']:
                print("✅ Sonos monitoring active")
            else:
                print("✅ Spotify monitoring active")
        
        # Start service recovery thread
        recovery_running = True
        recovery_thread = threading.Thread(target=service_recovery_loop, daemon=True)
        recovery_thread.start()
        
        # Get server configuration
        host = os.getenv('SERVER_HOST', '0.0.0.0')
        port = int(os.getenv('WEBSOCKET_SERVER_PORT', 5001))
        
        print(f"\n🚀 Starting server on {host}:{port}...")
        print("WebSocket endpoints:")
        
        # Show all accessible endpoints
        local_ips = get_local_ip()
        for ip in local_ips:
            protocol = 'wss' if ip.startswith('127.') or ip == 'localhost' else 'ws'
            print(f"  {protocol}://{ip}:{port}/")
        
        print("Press Ctrl+C to stop\n")
        
        # Start Flask-SocketIO server
        socketio.run(app, host=host, port=port, debug=False)
        
    except KeyboardInterrupt:
        print("\n\nShutting down...")
        recovery_running = False
        if recovery_thread:
            recovery_thread.join(timeout=2)
        for monitor in active_monitors:
            monitor.stop()
    except Exception as e:
        print(f"\n✗ Error: {e}")
        import traceback
        traceback.print_exc()
        return 1
    
    return 0

if __name__ == "__main__":
    exit(main())

# For Gunicorn: expose the app
# When running with gunicorn, the main() function won't be called automatically
# Instead, gunicorn will use the 'app' object directly
# The monitors need to be initialized here for gunicorn workers
import atexit

def initialize_for_gunicorn():
    """Initialize monitors when running under gunicorn"""
    global desired_services, recovery_running, recovery_thread
    
    if not active_monitors:  # Only initialize if not already done
        try:
            service_method = os.getenv('MEDIA_SERVICE_METHOD', 'all').lower().strip()
            
            # Set desired services based on configuration
            if service_method == 'spotify':
                desired_services = {'spotify'}
            elif service_method == 'sonos':
                desired_services = {'sonos'}
            else:  # 'all'
                desired_services = {'sonos', 'spotify'}
            
            print("\n🔧 Initializing playback monitoring (Gunicorn mode)...")
            print(f"Configuration: MEDIA_SERVICE_METHOD={service_method.upper()}\n")
            
            if service_method == 'spotify':
                monitor = initialize_spotify()
                active_monitors.append(monitor)
                print("✅ Spotify monitoring active")
                
            elif service_method == 'sonos':
                device_monitor = DeviceMonitor()
                if device_monitor.start():
                    active_monitors.append(device_monitor)
                    print("✅ Sonos monitoring active")
                    
            else:  # 'all'
                # Initialize both in parallel
                sonos_result = {'started': False, 'monitor': None}
                spotify_result = {'started': False, 'monitor': None}
                
                def init_sonos():
                    try:
                        if SONOS_AVAILABLE:
                            device_monitor = DeviceMonitor()
                            if device_monitor.start():
                                sonos_result['monitor'] = device_monitor
                                sonos_result['started'] = True
                    except Exception as e:
                        print(f"⚠️  Sonos initialization failed: {e}")
                
                def init_spotify():
                    try:
                        spotify_monitor = initialize_spotify()
                        spotify_result['monitor'] = spotify_monitor
                        spotify_result['started'] = True
                    except Exception as e:
                        print(f"⚠️  Spotify initialization failed: {e}")
                
                sonos_thread = threading.Thread(target=init_sonos, daemon=True)
                spotify_thread = threading.Thread(target=init_spotify, daemon=True)
                
                sonos_thread.start()
                spotify_thread.start()
                
                # Wait for threads
                sonos_thread.join(timeout=10)
                spotify_thread.join(timeout=10)
                
                if sonos_result['started'] and sonos_result['monitor']:
                    active_monitors.append(sonos_result['monitor'])
                
                if spotify_result['started'] and spotify_result['monitor']:
                    active_monitors.append(spotify_result['monitor'])
                
                if sonos_result['started'] or spotify_result['started']:
                    print("✅ Monitoring services initialized")
            
            # Start service recovery thread
            if not recovery_running:
                recovery_running = True
                recovery_thread = threading.Thread(target=service_recovery_loop, daemon=True)
                recovery_thread.start()
                    
        except Exception as e:
            print(f"⚠️  Error initializing monitors: {e}")

# Register cleanup handler
def cleanup_monitors():
    """Clean up monitors on shutdown"""
    global recovery_running, recovery_thread
    
    # Stop recovery thread
    recovery_running = False
    if recovery_thread:
        try:
            recovery_thread.join(timeout=2)
        except:
            pass
    
    # Stop all monitors
    for monitor in active_monitors:
        try:
            monitor.stop()
        except:
            pass

atexit.register(cleanup_monitors)

# Initialize monitors if running under gunicorn
# Check if we're being imported by gunicorn
if 'gunicorn' in os.environ.get('SERVER_SOFTWARE', ''):
    initialize_for_gunicorn()
