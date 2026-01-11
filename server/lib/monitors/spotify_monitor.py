"""
Spotify Monitor
Monitors Spotify playback and broadcasts updates
"""
import time
from typing import Optional, Dict, Any
from lib.monitors.base import BaseMonitor

class SpotifyMonitor(BaseMonitor):
    """Monitor Spotify playback and broadcast updates"""
    
    def __init__(self, spotify_client, app_state, socketio):
        """
        Initialize Spotify monitor
        
        Args:
            spotify_client: Authenticated Spotify client
            app_state: Application state object
            socketio: SocketIO instance for broadcasting
        """
        super().__init__(source_priority=2)  # Spotify has lower priority than Sonos
        self.sp = spotify_client
        self.app_state = app_state
        self.socketio = socketio
        self.last_device_name: Optional[str] = None
    
    def get_current_playback(self) -> Optional[Dict[str, Any]]:
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
    
    def _monitor_loop(self):
        """Main monitoring loop"""
        print("Starting Spotify playback monitor...")
        
        while self.is_running:
            try:
                track_data = self.get_current_playback()
                current_time = time.time()
                current_track_data = self.app_state.get_track_data()
                
                if track_data:
                    track_id = track_data['track_id']
                    device_name = track_data['device']['name']
                    
                    # Create comparable track identifier
                    comparable_track_id = self.create_track_identifier(track_data)
                    current_comparable_id = self.create_track_identifier(current_track_data) if current_track_data else None
                    
                    # Check if we should take over or update
                    time_since_last_update = current_time - (current_track_data.get('timestamp', 0) if current_track_data else 0)
                    
                    device_changed = device_name != self.last_device_name
                    is_our_source = current_track_data and current_track_data.get('source') == 'spotify'
                    
                    # Determine if we should update
                    major_change = (
                        track_id != self.last_track_id or
                        device_changed or
                        current_track_data is None or
                        track_data['is_playing'] != current_track_data.get('is_playing')
                    )
                    
                    # Can we take over?
                    can_take_over = self.should_source_takeover(current_track_data, time_since_last_update)
                    
                    # For progress updates: only send if clients need progress
                    needs_progress_update = is_our_source and self.app_state.has_clients_needing_progress()
                    
                    should_update = (major_change and can_take_over) or needs_progress_update
                    
                    if should_update:
                        self.last_track_id = track_id
                        self.last_device_name = device_name
                        self.last_update_time = current_time
                        
                        # Log when switching to Spotify as progress source
                        if major_change and (current_track_data is None or current_track_data.get('source') != 'spotify'):
                            print("📊 Progress source: SPOTIFY (fallback)")
                        
                        self.app_state.update_track_data(track_data)
                        
                        try:
                            self.socketio.emit('track_update', track_data, namespace='/')
                        except Exception:
                            pass
                        
                        # Only log major changes, not every position update
                        if major_change:
                            status = '🎵' if track_data['is_playing'] else '⏸️'
                            print(f"{status} [SPOTIFY] {track_data['track_name']} - {track_data['artist']}")
                
                elif current_track_data is not None and current_track_data.get('source') == 'spotify':
                    # Only clear if current source is Spotify
                    self.app_state.update_track_data(None)
                    self.last_track_id = None
                    self.last_device_name = None
                    try:
                        self.socketio.emit('track_update', None, namespace='/')
                    except Exception:
                        pass
                    print("⏹️  [SPOTIFY] No track playing")
                
                # Sleep for 2 seconds before next check
                time.sleep(2)
                
            except Exception as e:
                print(f"Error in Spotify monitor loop: {e}")
                time.sleep(5)
    
    def start(self) -> bool:
        """Start monitoring in background thread"""
        self._start_thread(self._monitor_loop)
        print("✓ Spotify monitor started")
        return True
    
    def stop(self):
        """Stop monitoring"""
        self._stop_thread()
        print("Spotify monitor stopped")
