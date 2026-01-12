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
from typing import Dict, Any, Optional, Set
from flask import Flask, jsonify, send_from_directory, Response, request
from flask_socketio import SocketIO, emit
from flask_cors import CORS
import urllib3
import atexit
from config import Config

# Import library modules
from lib.app_state import AppState
from lib.monitors.spotify_monitor import SpotifyMonitor
from lib.monitors.sonos_monitor import SonosMonitor, SONOS_AVAILABLE
from lib.auth.spotify_auth import SpotifyAuthWithServer
from lib.utils.network import get_local_ip
from lib.utils.logger import server_logger

# Configure SSL verification for Spotify API (from Config)
if not Config.SSL_VERIFY_SPOTIFY:
    server_logger.warning("⚠️  SSL certificate verification DISABLED for Spotify endpoints")
    server_logger.warning("   Applies to: api.spotify.com, accounts.spotify.com")
    server_logger.warning("   This should only be used in development/testing environments")
    # Suppress only the InsecureRequestWarning from urllib3
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
else:
    server_logger.info("✓ SSL certificate verification ENABLED for all Spotify endpoints")

# Suppress werkzeug logging for WebSocket disconnect errors
logging.getLogger('werkzeug').setLevel(logging.ERROR)
werkzeug_logger = logging.getLogger('werkzeug')
werkzeug_logger.addFilter(lambda record: 'write() before start_response' not in str(record.getMessage()))

# Flask app setup
app = Flask(__name__)
app.config['SECRET_KEY'] = Config.SECRET_KEY
app.config['SEND_FILE_MAX_AGE_DEFAULT'] = Config.SEND_FILE_MAX_AGE_DEFAULT
CORS(app)

# Configure Socket.IO with custom path for nginx subpath proxying
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='threading', path=Config.WEBSOCKET_PATH)

# Override Flask-SocketIO's aggressive no-cache defaults for static assets
@app.after_request
def after_request(response):
    # Only modify cache headers for asset routes
    if '/assets/' in request.path:
        server_logger.debug(f"Processing asset route: {request.path}")
        server_logger.debug(f"Cache-Control before: {response.headers.get('Cache-Control', 'NOT SET')}")
        
        # Always override cache headers for assets - Flask-SocketIO sets bad defaults
        if '/screensavers/' in request.path:
            if request.path.endswith('/'):
                # Directory listing - cache for 1 hour
                response.headers['Cache-Control'] = 'public, max-age=3600'
                server_logger.debug("Set Cache-Control for directory listing")
            else:
                # Individual image - cache for 1 day
                response.headers['Cache-Control'] = 'public, max-age=86400, immutable'
                server_logger.debug("Set Cache-Control for image")
        else:
            # Default for other assets - cache for 1 day
            response.headers['Cache-Control'] = 'public, max-age=86400'
            server_logger.debug("Set Cache-Control for other asset")
        
        # Remove conflicting headers that prevent caching
        response.headers.pop('Pragma', None)
        if 'Expires' in response.headers:
            response.headers.pop('Expires')
        
        server_logger.debug(f"Cache-Control after: {response.headers.get('Cache-Control', 'NOT SET')}")
    return response

# Global state
app_state: AppState = AppState()
desired_services: Set[str] = set()  # Services that should be active based on MEDIA_SERVICE_METHOD
recovery_thread: Optional[threading.Thread] = None  # Background thread for service recovery
recovery_running: bool = False  # Control flag for recovery thread

# All OAuth and monitor classes are now imported from lib/

# WebSocket event handlers
def get_active_services() -> Dict[str, bool]:
    """Get dictionary of currently active services"""
    return app_state.get_active_services()

def broadcast_service_status() -> None:
    """Broadcast service status to all connected clients"""
    active_services = get_active_services()
    try:
        socketio.emit('service_status', active_services, namespace='/')
    except Exception as e:
        server_logger.error(f"⚠️  Error broadcasting service status: {e}")

def is_service_active(service_name: str) -> bool:
    """Check if a specific service is currently active"""
    return app_state.is_service_active(service_name)

def get_service_monitor(service_name: str) -> Optional[Any]:
    """Get the monitor instance for a specific service"""
    for m in app_state.active_monitors:
        if service_name == 'sonos' and isinstance(m, SonosMonitor):
            return m
        elif service_name == 'spotify' and isinstance(m, SpotifyMonitor):
            return m
    return None

@socketio.on('connect')
def handle_connect():
    app_state.connected_clients += 1
    server_logger.info(f"Client connected. Total clients: {app_state.connected_clients}")
    
    # Send current service status
    active_services = get_active_services()
    emit('service_status', active_services)
    
    # Send current track immediately upon connection
    current_track = app_state.get_track_data()
    if current_track:
        emit('track_update', current_track)

@socketio.on('disconnect')
def handle_disconnect():
    try:
        client_id = request.sid  # type: ignore
        app_state.connected_clients -= 1
        server_logger.info(f"Client disconnected: {client_id[:8]}... Total clients: {app_state.connected_clients}")
        
        # Remove from progress tracking if present
        app_state.remove_client_needing_progress(client_id)
        if len(app_state.clients_needing_progress) == 0:
            server_logger.info("📊 Stopping progress tracking (no clients need it)")
    except Exception:
        # Suppress werkzeug disconnect errors
        pass

@socketio.on('request_current_track')
def handle_request_current_track():
    """Client requests current track info"""
    current_track = app_state.get_track_data()
    if current_track:
        emit('track_update', current_track)
    else:
        emit('track_update', None)

@socketio.on('enable_progress')
def handle_enable_progress():
    """Client enables progress effects and needs progress updates"""
    client_id = request.sid  # type: ignore
    
    # Log which service is currently active
    current_track = app_state.get_track_data()
    current_source = current_track.get('source', 'none').upper() if current_track else 'NONE'
    server_logger.info(f"📡 Received 'enable_progress' from client {client_id[:8]}... (Active source: {current_source})")
    
    if app_state.add_client_needing_progress(client_id):
        server_logger.info(f"✅ Progress updates enabled for client {client_id[:8]}... (Total: {len(app_state.clients_needing_progress)})")
        
        # If this is the first client needing progress, log the change
        if len(app_state.clients_needing_progress) == 1:
            server_logger.info("📊 Starting progress tracking (client requested)")

@socketio.on('disable_progress')
def handle_disable_progress():
    """Client disables progress effects and no longer needs progress updates"""
    client_id = request.sid  # type: ignore
    
    server_logger.info(f"📡 Received 'disable_progress' from client {client_id[:8]}...")
    
    if app_state.remove_client_needing_progress(client_id):
        server_logger.info(f"⏸️  Progress updates disabled for client {client_id[:8]}... (Total: {len(app_state.clients_needing_progress)})")
        
        # If no clients need progress anymore, log the change
        if len(app_state.clients_needing_progress) == 0:
            server_logger.info("📊 Stopping progress tracking (no clients need it)")

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
    active_sources = [m.__class__.__name__ for m in app_state.active_monitors]
    current_track = app_state.get_track_data()
    return jsonify({
        'status': 'ok',
        'connected_clients': app_state.connected_clients,
        'active_monitors': active_sources,
        'current_track': current_track is not None,
        'current_source': current_track.get('source') if current_track else None
    })

@app.route('/assets/images/screensavers/')
def list_screensaver_images():
    """List screensaver images with directory listing"""
    screensaver_dir = Config.SCREENSAVER_DIR
    
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
    screensaver_dir = Config.SCREENSAVER_DIR
    
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
    
    if not Config.SPOTIFY_CLIENT_ID or not Config.SPOTIFY_CLIENT_SECRET:
        raise Exception("SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET must be set")
    
    # Initialize auth (port from Config or parsed from redirect_uri)
    auth = SpotifyAuthWithServer(
        client_id=Config.SPOTIFY_CLIENT_ID,
        client_secret=Config.SPOTIFY_CLIENT_SECRET,
        redirect_uri=Config.SPOTIFY_REDIRECT_URI,
        scope=Config.SPOTIFY_SCOPE,
        local_port=Config.LOCAL_CALLBACK_PORT
    )
    
    # Get authenticated client
    spotify_client = auth.get_spotify_client()
    
    # Verify authentication by making a test call
    try:
        spotify_client.current_user()
        server_logger.info("✓ Spotify authentication successful!")
    except Exception as e:
        raise Exception(f"Spotify authentication failed: {e}")
    
    # Start monitoring (passing app_state and socketio)
    monitor = SpotifyMonitor(spotify_client, app_state, socketio)
    monitor.start()
    
    return monitor

def try_start_sonos() -> bool:
    """Attempt to start Sonos monitoring, return True if successful"""
    
    if not SONOS_AVAILABLE:
        return False
    
    try:
        # Check if already active
        if is_service_active('sonos'):
            return True
        
        # Remove any old inactive Sonos monitor
        app_state.active_monitors = [m for m in app_state.active_monitors if not isinstance(m, SonosMonitor)]
        
        # Try to start new monitor
        device_monitor = SonosMonitor(app_state, socketio)
        if device_monitor.start():
            app_state.add_monitor(device_monitor)
            server_logger.info("✅ Sonos service recovered and activated")
            broadcast_service_status()
            return True
        else:
            return False
    except Exception as e:
        server_logger.warning(f"⚠️  Sonos recovery attempt failed: {e}")
        return False

def try_start_spotify() -> bool:
    """Attempt to start Spotify monitoring, return True if successful"""
    
    try:
        # Check if already active
        if is_service_active('spotify'):
            return True
        
        # Remove any old inactive Spotify monitor
        app_state.active_monitors = [m for m in app_state.active_monitors if not isinstance(m, SpotifyMonitor)]
        
        # Try to start new monitor
        monitor = initialize_spotify()
        app_state.add_monitor(monitor)
        server_logger.info("✅ Spotify service recovered and activated")
        
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
                server_logger.info("✅ Spotify service is active (callback server already running)")
                broadcast_service_status()
                return True
        server_logger.warning(f"⚠️  Spotify recovery attempt failed: {e}")
        return False
    except Exception as e:
        server_logger.warning(f"⚠️  Spotify recovery attempt failed: {e}")
        return False

def service_recovery_loop() -> None:
    """Background thread that continuously monitors and recovers failed services"""
    global recovery_running, desired_services
    
    retry_count: dict[str, int] = {'sonos': 0, 'spotify': 0}
    first_failure_time: dict[str, float | None] = {'sonos': None, 'spotify': None}
    max_retry_duration = Config.SERVICE_RECOVERY_TIMEOUT_MINUTES * 60
    timeout_minutes = Config.SERVICE_RECOVERY_TIMEOUT_MINUTES
    
    # Give initial startup time before starting recovery checks
    server_logger.info("🔄 Service recovery thread started")
    server_logger.info(f"   Monitoring services: {', '.join(sorted(desired_services))}")
    server_logger.info(f"   Waiting {Config.SERVICE_RECOVERY_INITIAL_DELAY}s for initial service startup...")
    time.sleep(Config.SERVICE_RECOVERY_INITIAL_DELAY)
    
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
                            server_logger.warning(f"⏱️  {service.upper()} service recovery timeout ({timeout_minutes} minute{'s' if timeout_minutes != 1 else ''} exceeded)")
                            server_logger.warning(f"   Stopped retrying after {retry_count[service]} attempts")
                            retry_count[service] = -1  # Mark as timed out
                        continue  # Skip this service
                    
                    retry_count[service] += 1
                    remaining_time = int(max_retry_duration - elapsed_time)
                    server_logger.info(f"🔄 Attempting to recover {service.upper()} service (attempt #{retry_count[service]}, timeout in {remaining_time}s)...")
                    
                    success = False
                    if service == 'sonos':
                        success = try_start_sonos()
                    elif service == 'spotify':
                        success = try_start_spotify()
                    
                    if success:
                        retry_count[service] = 0  # Reset counter on success
                        first_failure_time[service] = None
                    else:
                        server_logger.warning(f"⚠️  {service.upper()} recovery failed. Will retry in 30 seconds...")
                else:
                    # Service is active, reset retry counter and failure time
                    if retry_count[service] != 0:
                        if retry_count[service] > 0:
                            server_logger.info(f"✅ {service.upper()} service is healthy again")
                        retry_count[service] = 0
                        first_failure_time[service] = None
                    
                    # Verify service is still healthy
                    monitor = get_service_monitor(service)
                    if monitor:
                        if not monitor.is_running or not monitor.is_ready:
                            server_logger.warning(f"⚠️  {service.upper()} service detected as unhealthy, marking for recovery...")
                            monitor.is_ready = False
                            if monitor in app_state.active_monitors:
                                app_state.remove_monitor(monitor)
                            broadcast_service_status()
            
            # Sleep for 30 seconds before next check (increased from 10s)
            time.sleep(30)
            
        except Exception as e:
            server_logger.error(f"⚠️  Error in service recovery loop: {e}")
            time.sleep(30)
    
    server_logger.info("🔄 Service recovery thread stopped")

def main() -> int:
    """Main entry point"""
    server_logger.info("=" * 60)
    server_logger.info("Now Playing Server (Multi-Source Monitor)")
    server_logger.info("=" * 60)
    
    global desired_services, recovery_running, recovery_thread
    
    try:
        # Validate and print configuration
        Config.validate()
        Config.print_config()
        
        # Set desired services based on configuration
        desired_services = Config.get_desired_services()
        
        server_logger.info("🔧 Initializing playback monitoring...")
        server_logger.info(f"Configuration: MEDIA_SERVICE_METHOD={Config.MEDIA_SERVICE_METHOD.upper()}")
        
        if Config.MEDIA_SERVICE_METHOD == 'spotify':
            # Spotify only
            server_logger.info("=" * 60)
            server_logger.info("Mode: Spotify Connect Only")
            server_logger.info("=" * 60)
            
            monitor = initialize_spotify()
            app_state.add_monitor(monitor)
            server_logger.info("✅ Spotify monitoring active")
            
        elif Config.MEDIA_SERVICE_METHOD == 'sonos':
            # Sonos only
            server_logger.info("=" * 60)
            server_logger.info("Mode: Sonos API Only")
            server_logger.info("=" * 60)
            
            device_monitor = SonosMonitor(app_state, socketio)
            if device_monitor.start():
                app_state.add_monitor(device_monitor)
                server_logger.info("✅ Sonos monitoring active")
            else:
                server_logger.error("✗ Failed to start Sonos monitoring")
                return 1
                
        else:  # Config.MEDIA_SERVICE_METHOD == 'all'
            # Monitor BOTH simultaneously
            server_logger.info("=" * 60)
            # Use threading to initialize services in parallel
            sonos_result = {'started': False, 'monitor': None}
            spotify_result = {'started': False, 'monitor': None}
            
            def init_sonos():
                """Initialize Sonos in background thread"""
                server_logger.info("🔵 Starting Sonos monitor...")
                try:
                    if SONOS_AVAILABLE:
                        device_monitor = SonosMonitor(app_state, socketio)
                        if device_monitor.start():
                            sonos_result['monitor'] = device_monitor
                            sonos_result['started'] = True
                            server_logger.info("✅ Sonos monitoring active")
                        else:
                            server_logger.warning("⚠️  Sonos monitoring unavailable (no devices found)")
                    else:
                        server_logger.warning("⚠️  Sonos library not installed")
                except Exception as e:
                    server_logger.warning(f"⚠️  Sonos initialization failed: {e}")
            
            def init_spotify():
                """Initialize Spotify in background thread"""
                server_logger.info("🟢 Starting Spotify monitor...")
                try:
                    spotify_monitor = initialize_spotify()
                    spotify_result['monitor'] = spotify_monitor
                    spotify_result['started'] = True
                    server_logger.info("✅ Spotify monitoring active")
                except Exception as e:
                    server_logger.warning(f"⚠️  Spotify monitoring unavailable: {e}")
            
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
                    server_logger.info(f"At least one service ready after {i+1}s")
                    break
                    
                # If both threads have finished but neither succeeded, exit early
                if not sonos_thread.is_alive() and not spotify_thread.is_alive():
                    break
            
            # Give remaining thread a bit more time if needed, but don't block
            if sonos_thread.is_alive():
                sonos_thread.join(timeout=2)
            if spotify_thread.is_alive():
                spotify_thread.join(timeout=2)
            
            # Add successfully started monitors to active list
            if sonos_result['started'] and sonos_result['monitor']:
                app_state.add_monitor(sonos_result['monitor'])
            
            if spotify_result['started'] and spotify_result['monitor']:
                app_state.add_monitor(spotify_result['monitor'])
            
            # Check if at least one monitor started
            if not sonos_result['started'] and not spotify_result['started']:
                server_logger.error("✗ Failed to start any monitoring service")
                return 1
            
            if sonos_result['started'] and spotify_result['started']:
                server_logger.info("✅ Both Sonos and Spotify monitoring active (Sonos priority)")
            elif sonos_result['started']:
                server_logger.info("✅ Sonos monitoring active")
            else:
                server_logger.info("✅ Spotify monitoring active")
        
        # Start service recovery thread
        recovery_running = True
        recovery_thread = threading.Thread(target=service_recovery_loop, daemon=True)
        recovery_thread.start()
        
        # Get server configuration from Config
        host = Config.SERVER_HOST
        port = Config.WEBSOCKET_SERVER_PORT
        
        server_logger.info(f"🚀 Starting server on {host}:{port}...")
        server_logger.info("WebSocket endpoints:")
        
        # Show all accessible endpoints
        local_ips = get_local_ip()
        for ip in local_ips:
            protocol = 'wss' if ip.startswith('127.') or ip == 'localhost' else 'ws'
            server_logger.info(f"  {protocol}://{ip}:{port}/")
        
        server_logger.info("Press Ctrl+C to stop")
        
        # Start Flask-SocketIO server
        socketio.run(app, host=host, port=port, debug=False)
        
    except KeyboardInterrupt:
        server_logger.info("\nShutting down...")
        recovery_running = False
        if recovery_thread:
            recovery_thread.join(timeout=2)
        for monitor in app_state.active_monitors:
            monitor.stop()
    except Exception as e:
        server_logger.error(f"✗ Error: {e}")
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
    
    if not app_state.active_monitors:  # Only initialize if not already done
        try:
            # Validate configuration
            Config.validate()
            
            service_method = Config.MEDIA_SERVICE_METHOD
            
            # Set desired services based on configuration
            if service_method == 'spotify':
                desired_services = {'spotify'}
            elif service_method == 'sonos':
                desired_services = {'sonos'}
            else:  # 'all'
                desired_services = {'sonos', 'spotify'}
            
            server_logger.info("🔧 Initializing playback monitoring (Gunicorn mode)...")
            server_logger.info(f"Configuration: MEDIA_SERVICE_METHOD={Config.MEDIA_SERVICE_METHOD.upper()}")
            
            if Config.MEDIA_SERVICE_METHOD == 'spotify':
                monitor = initialize_spotify()
                app_state.add_monitor(monitor)
                server_logger.info("✅ Spotify monitoring active")
                
            elif Config.MEDIA_SERVICE_METHOD == 'sonos':
                device_monitor = SonosMonitor(app_state, socketio)
                if device_monitor.start():
                    app_state.add_monitor(device_monitor)
                    server_logger.info("✅ Sonos monitoring active")
                    
            else:  # 'all'
                # Initialize both in parallel
                sonos_result = {'started': False, 'monitor': None}
                spotify_result = {'started': False, 'monitor': None}
                
                def init_sonos():
                    try:
                        if SONOS_AVAILABLE:
                            device_monitor = SonosMonitor(app_state, socketio)
                            if device_monitor.start():
                                sonos_result['monitor'] = device_monitor
                                sonos_result['started'] = True
                    except Exception as e:
                        server_logger.warning(f"⚠️  Sonos initialization failed: {e}")
                
                def init_spotify():
                    try:
                        spotify_monitor = initialize_spotify()
                        spotify_result['monitor'] = spotify_monitor
                        spotify_result['started'] = True
                    except Exception as e:
                        server_logger.warning(f"⚠️  Spotify initialization failed: {e}")
                
                sonos_thread = threading.Thread(target=init_sonos, daemon=True)
                spotify_thread = threading.Thread(target=init_spotify, daemon=True)
                
                sonos_thread.start()
                spotify_thread.start()
                
                # Wait for threads
                sonos_thread.join(timeout=10)
                spotify_thread.join(timeout=10)
                
                if sonos_result['started'] and sonos_result['monitor']:
                    app_state.add_monitor(sonos_result['monitor'])
                
                if spotify_result['started'] and spotify_result['monitor']:
                    app_state.add_monitor(spotify_result['monitor'])
                
                if sonos_result['started'] or spotify_result['started']:
                    server_logger.info("✅ Monitoring services initialized")
            
            # Start service recovery thread
            if not recovery_running:
                recovery_running = True
                recovery_thread = threading.Thread(target=service_recovery_loop, daemon=True)
                recovery_thread.start()
                    
        except Exception as e:
            server_logger.error(f"⚠️  Error initializing monitors: {e}")

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
    app_state.cleanup()

atexit.register(cleanup_monitors)

# Initialize monitors if running under gunicorn
# Check if we're being imported by gunicorn
if 'gunicorn' in os.environ.get('SERVER_SOFTWARE', ''):
    initialize_for_gunicorn()
