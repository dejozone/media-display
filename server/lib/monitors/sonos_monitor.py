"""
Sonos Monitor
Monitors Sonos devices for playback updates
"""
import time
import threading
from typing import Optional, Dict, Any, List

from lib.monitors.base import BaseMonitor
from lib.utils import parse_time_to_ms, format_device_display

# Check for Sonos availability
try:
    import soco
    from soco.events import event_listener
    SONOS_AVAILABLE = True
except ImportError:
    SONOS_AVAILABLE = False
    soco = None
    event_listener = None


class SonosMonitor(BaseMonitor):
    """Monitor Sonos devices for playback updates"""
    
    def __init__(self, app_state, socketio):
        """
        Initialize Sonos monitor
        
        Args:
            app_state: Application state object
            socketio: SocketIO instance for broadcasting
        """
        super().__init__(source_priority=1)  # Sonos has higher priority than Spotify
        self.app_state = app_state
        self.socketio = socketio
        self.devices: List[Dict[str, Any]] = []
        self.subscriptions: List[Any] = []
        self.polling_thread: Optional[threading.Thread] = None
        self.event_mode: bool = True  # True = use events, False = use polling fallback
        self.last_event_time: float = 0  # Track last successful event
        self.event_timeout: float = 30  # Seconds before considering events dead
    
    def get_device_names(self, coordinator_device) -> List[str]:
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
    
    def discover_sonos_devices(self) -> bool:
        """Discover Sonos speakers on network"""
        if not SONOS_AVAILABLE or soco is None:
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
        try:
            # Update last event time to track event health
            self.last_event_time = time.time()
            
            # If we were in polling fallback mode, switch back to events
            if not self.event_mode:
                print("✅ [SONOS] Events recovered, switching from polling to event mode")
                self.event_mode = True
            
            # Get the parent service to access track info
            if hasattr(event.service, 'soco'):
                device = event.service.soco
                track = device.get_current_track_info()
                transport = device.get_current_transport_info()
                
                if track and track.get('title') and track.get('title') != '':
                    # Get device names list
                    device_names = self.get_device_names(device)
                    
                    # Parse duration and position (format: "H:MM:SS" or "M:SS")
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
                    
                    track_id = self.create_track_identifier(track_data)
                    current_time = time.time()
                    current_track_data = self.app_state.get_track_data()
                    
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
                        
                        self.app_state.update_track_data(track_data)
                        self.socketio.emit('track_update', track_data, namespace='/')
                        
                        status = '🎵' if track_data['is_playing'] else '⏸️'
                        print(f"{status} [SONOS] {track_data['track_name']} - {track_data['artist']}")
                        
        except Exception as e:
            print(f"Error handling Sonos event: {e}")
    
    def subscribe_to_devices(self) -> bool:
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
    
    def get_initial_state(self) -> Optional[Dict[str, Any]]:
        """Get current playback state from devices"""
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
                        self.app_state.update_track_data(track_data)
                        self.last_track_id = self.create_track_identifier(track_data)
                        self.last_update_time = time.time()
                        
                        # Format device names for logging
                        device_display = format_device_display(device_names)
                        print(f"  ℹ️  Initial state: {track_data['track_name']} - {track_data['artist']}")
                        print(f"  📱 Playing on: {device_display}")
                        return track_data
                        
                except Exception as e:
                    print(f"  ⚠️  Error getting initial state from {device_info['name']}: {e}")
        
        return None
    
    def _poll_position_updates(self):
        """
        Poll Sonos devices for position updates every 2 seconds.
        Also serves as fallback when event subscriptions fail.
        """
        while self.is_running:
            try:
                time.sleep(2)  # Poll every 2 seconds
                
                current_track_data = self.app_state.get_track_data()
                
                # Check if events have stopped working (no events in last 30 seconds while playing)
                if self.event_mode and current_track_data and current_track_data.get('source') == 'sonos':
                    time_since_event = time.time() - self.last_event_time
                    if time_since_event > self.event_timeout and current_track_data.get('is_playing'):
                        print(f"⚠️  [SONOS] No events received for {int(time_since_event)}s, switching to polling fallback")
                        self.event_mode = False
                
                # Poll if: (1) clients need progress OR (2) event mode has failed
                should_poll = (
                    current_track_data and 
                    current_track_data.get('source') == 'sonos' and
                    (self.app_state.has_clients_needing_progress() or not self.event_mode)
                )
                
                if should_poll:
                    for device_info in self.devices:
                        if device_info['type'] == 'sonos':
                            try:
                                device = device_info['device']
                                track = device.get_current_track_info()
                                transport = device.get_current_transport_info()
                                
                                if track and track.get('title'):
                                    # Parse position
                                    position_ms = parse_time_to_ms(track.get('position', '0:00:00'))
                                    duration_ms = parse_time_to_ms(track.get('duration', '0:00:00'))
                                    is_playing = transport.get('current_transport_state') == 'PLAYING'
                                    
                                    # In polling fallback mode, check for track changes
                                    if not self.event_mode:
                                        track_id = f"{track.get('title')}_{track.get('artist')}"
                                        if self.last_track_id != track_id:
                                            print(f"🔄 [SONOS POLL] Track changed: {track.get('title')} - {track.get('artist')}")
                                            self.last_track_id = track_id
                                            
                                            # Get full track data
                                            device_names = self.get_device_names(device)
                                            current_track_data = {
                                                'track_name': track.get('title', 'Unknown'),
                                                'artist': track.get('artist', 'Unknown Artist'),
                                                'album': track.get('album', 'Unknown Album'),
                                                'album_art': track.get('album_art', None),
                                                'is_playing': is_playing,
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
                                            self.app_state.update_track_data(current_track_data)
                                    
                                    # Update position (works in both modes)
                                    if current_track_data:
                                        current_track_data['progress_ms'] = position_ms
                                        current_track_data['duration_ms'] = duration_ms
                                        current_track_data['is_playing'] = is_playing
                                        current_track_data['timestamp'] = time.time()
                                        
                                        self.app_state.update_track_data(current_track_data)
                                        
                                        # Broadcast update
                                        self.socketio.emit('track_update', current_track_data, namespace='/')
                                
                                break  # Only need to poll one device
                                
                            except Exception as e:
                                print(f"⚠️  [SONOS] Polling error: {e}")
                                # If polling fails repeatedly, events are likely still better
                                if not self.event_mode:
                                    print("⚠️  [SONOS] Polling also failing, will retry event mode")
                                    self.event_mode = True
                                
            except Exception as e:
                print(f"⚠️  [SONOS] Position polling loop error: {e}")
    
    def get_current_playback(self) -> Optional[Dict[str, Any]]:
        """Get current playback information"""
        # For Sonos, current playback is maintained via events and polling
        return self.app_state.get_track_data() if self.app_state.get_track_data() and self.app_state.get_track_data().get('source') == 'sonos' else None
    
    def start(self) -> bool:
        """Start monitoring devices"""
        if not self.is_running:
            self.is_running = True
            
            # Discover devices
            has_devices = self.discover_sonos_devices()
            
            if not has_devices:
                print("\n⚠️  No Sonos devices found on network")
                self.is_running = False
                return False
            
            # Subscribe to events (primary mechanism)
            events_active = self.subscribe_to_devices()
            if not events_active:
                print("\n⚠️  Failed to subscribe to events, will use polling fallback")
                self.event_mode = False
            else:
                print("✅ Event subscriptions active (primary mode)")
                self.event_mode = True
                self.last_event_time = time.time()  # Initialize event timer
            
            # Get initial state
            self.get_initial_state()
            
            # Start polling thread (handles both position updates and fallback)
            self.polling_thread = threading.Thread(target=self._poll_position_updates, daemon=True)
            self.polling_thread.start()
            
            self.is_ready = True
            mode_str = "events (primary) + polling (position)" if events_active else "polling (fallback)"
            print(f"\n✅ Sonos monitoring started - Mode: {mode_str}")
            return True
        
        return False
    
    def stop(self):
        """Stop monitoring and unsubscribe"""
        self.is_running = False
        self.is_ready = False
        
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
