"""
Spotify Monitor
Monitors Spotify playback and broadcasts updates
"""
import time
from typing import Optional, Dict, Any
from lib.monitors.base import BaseMonitor
from lib.utils.logger import monitor_logger
from config import Config

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
        
        # Pause polling optimization
        self.consecutive_no_playback_count: int = 0
        self.polling_paused: bool = False
        
        # Connection retry tracking
        self.connection_errors: int = 0
        self.last_connection_error_time: Optional[float] = None
        self.api_unreachable_start: Optional[float] = None
        self.needs_reconnection: bool = False  # Flag to trigger reconnection attempts
        
        # Connection retry tracking
        self.connection_errors: int = 0
        self.last_connection_error_time: Optional[float] = None
        self.api_unreachable_start: Optional[float] = None
        self.needs_reconnection: bool = False  # Flag to trigger reconnection attempts
    
    def _handle_connection_error(self, error: Exception) -> None:
        """Handle connection errors with retry logic"""
        from config import Config
        
        current_time = time.time()
        self.connection_errors += 1
        self.last_connection_error_time = current_time
        
        # Track when API first became unreachable
        if self.api_unreachable_start is None:
            self.api_unreachable_start = current_time
            monitor_logger.warning(f"⚠️  [SPOTIFY] API connection lost: {error}")
            monitor_logger.info(f"🔄 Starting retry attempts (every {Config.SPOTIFY_RETRY_INTERVAL}s for up to {Config.SPOTIFY_DEVICE_RETRY_WINDOW_TIME}s)")
        
        # Mark that we need to attempt reconnection
        self.needs_reconnection = True
        
        # Check if we've exceeded retry window
        elapsed = current_time - self.api_unreachable_start
        if elapsed > Config.SPOTIFY_DEVICE_RETRY_WINDOW_TIME:
            monitor_logger.error(f"❌ [SPOTIFY] API unreachable for {int(elapsed)}s (exceeded {Config.SPOTIFY_DEVICE_RETRY_WINDOW_TIME}s limit)")
            monitor_logger.error(f"Total connection errors: {self.connection_errors}")
            monitor_logger.error(f"Marking service as unhealthy for recovery")
            self.is_ready = False
            self.needs_reconnection = False
        else:
            remaining = Config.SPOTIFY_DEVICE_RETRY_WINDOW_TIME - elapsed
            monitor_logger.warning(f"⚠️  [SPOTIFY] Connection error #{self.connection_errors}: {error}")
            monitor_logger.info(f"🔄 Will retry API call in {Config.SPOTIFY_RETRY_INTERVAL}s (timeout in {int(remaining)}s)")
    
    def _reset_connection_tracking(self) -> None:
        """Reset connection error tracking after successful operation"""
        if self.connection_errors > 0:
            monitor_logger.info(f"✅ [SPOTIFY] API connection restored after {self.connection_errors} errors")
        self.connection_errors = 0
        self.last_connection_error_time = None
        self.api_unreachable_start = None
        self.needs_reconnection = False
    
    def get_current_playback(self) -> Optional[Dict[str, Any]]:
        """Get current playback information"""
        try:
            current = self.sp.current_playback()
            
            # Reset connection error tracking on successful API call
            self._reset_connection_tracking()
            
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
            # Check if this is a connection error
            error_str = str(e)
            is_connection_error = any(keyword in error_str.lower() for keyword in 
                ['connection', 'refused', 'reset', 'timeout', 'unreachable', 'max retries', 'ssl', 'certificate'])
            
            if is_connection_error:
                self._handle_connection_error(e)
            else:
                monitor_logger.error(f"Error getting playback: {e}")
            return None
    
    def _monitor_loop(self):
        """Main monitoring loop"""
        from config import Config
        monitor_logger.info("Starting Spotify playback monitor...")
        
        while self.is_running:
            try:
                # Check if we need to attempt reconnection
                if self.needs_reconnection:
                    from config import Config
                    
                    # Check if we're still within retry window
                    if self.api_unreachable_start:
                        elapsed = time.time() - self.api_unreachable_start
                        if elapsed <= Config.SPOTIFY_DEVICE_RETRY_WINDOW_TIME:
                            # Wait before retry
                            time.sleep(Config.SPOTIFY_RETRY_INTERVAL)
                            
                            # Try to make an API call to test connection
                            monitor_logger.info("🔄 [SPOTIFY] Attempting to reconnect to API...")
                            track_data = self.get_current_playback()
                            
                            if not self.needs_reconnection:
                                # Connection was successful (reset was called)
                                monitor_logger.info("✅ [SPOTIFY] API reconnection successful, resuming normal operation")
                            else:
                                # Still failing
                                remaining = Config.SPOTIFY_DEVICE_RETRY_WINDOW_TIME - elapsed
                                if remaining <= 60:
                                    time_str = f"{int(remaining)}s"
                                else:
                                    time_str = f"{remaining / 60:.1f}min"
                                monitor_logger.warning(f"⚠️  [SPOTIFY] Reconnection attempt failed, will retry... (timeout in {time_str})")
                        else:
                            # Exceeded retry window, mark as failed
                            self._handle_connection_error(Exception("Retry window exceeded"))
                    
                    continue
                
                # OPTIMIZATION: Check if higher-priority source is active BEFORE polling
                # This reduces unnecessary API calls when Sonos (or other higher-priority sources) are playing
                # Uses shared method from BaseMonitor - easy to extend for new services
                if self.should_use_reduced_polling(self.app_state, Config.SPOTIFY_TAKEOVER_WAIT_TIME):
                    current_track_data = self.app_state.get_track_data()
                    # monitor_logger.debug(f"[SPOTIFY] Higher-priority source ({current_track_data.get('source')}) active, using reduced polling")
                    time.sleep(Config.SPOTIFY_REDUCED_POLLING_INTERVAL)
                    continue
                
                # If polling is paused, check less frequently
                if self.polling_paused:
                    time.sleep(Config.SPOTIFY_PAUSED_POLLING_INTERVAL)
                    
                    # Quick check if playback resumed
                    track_data = self.get_current_playback()
                    if track_data and track_data.get('is_playing'):
                        monitor_logger.info("🎵 [SPOTIFY] Playback resumed, resuming normal polling")
                        self.polling_paused = False
                        self.consecutive_no_playback_count = 0
                        # Continue to normal processing below
                    else:
                        # Still no playback, continue paused polling
                        continue
                
                track_data = self.get_current_playback()
                current_time = time.time()
                # Re-fetch current track data in case it changed during API call
                current_track_data = self.app_state.get_track_data()
                
                # Check for no playback and enter paused polling mode if needed
                if not track_data or not track_data.get('is_playing'):
                    self.consecutive_no_playback_count += 1
                    
                    # After configured consecutive checks with no playback, pause polling
                    if self.consecutive_no_playback_count >= Config.SPOTIFY_CONSECUTIVE_NO_POLLS_BEFORE_PAUSE:
                        monitor_logger.info(f"⏸️  [SPOTIFY] No playback detected for {self.consecutive_no_playback_count * 2}s, reducing polling frequency")
                        self.polling_paused = True
                        self.consecutive_no_playback_count = 0
                        
                        # Clear current track if it was from Spotify
                        if current_track_data and current_track_data.get('source') == 'spotify':
                            self.app_state.update_track_data(None)
                            try:
                                self.socketio.emit('track_update', None, namespace='/')
                            except Exception:
                                pass
                            monitor_logger.info("⏹️  [SPOTIFY] No track playing")
                    
                    time.sleep(2)
                    continue
                
                # Reset counter when playback is active
                self.consecutive_no_playback_count = 0
                
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
                    
                    # OPTIMIZATION: Don't take over from higher-priority sources if playing SAME track on SAME device
                    # This prevents ping-pong when Sonos plays Spotify content
                    # BUT allow takeover if device changed (user explicitly switched to phone/laptop)
                    if current_track_data and current_track_data.get('source_priority', 999) < self.source_priority:
                        # Higher priority source (like Sonos) is active
                        # Check if it's the same track AND same device
                        current_device = current_track_data.get('device', {}).get('name', '')
                        new_device = track_data.get('device', {}).get('name', '')
                        
                        if comparable_track_id == current_comparable_id and not device_changed:
                            # Same track, same device - don't interfere, respect higher priority
                            # monitor_logger.debug(f"[SPOTIFY] Skipping update - {current_track_data.get('source', 'unknown').upper()} already playing same track on same device")
                            time.sleep(2)
                            continue
                        else:
                            # Different track OR different device - user explicitly chose Spotify
                            if device_changed:
                                monitor_logger.info(f"📊 [SPOTIFY] Device changed - user switched to Spotify on {new_device}")
                            # else:
                            #     monitor_logger.info(f"📊 [SPOTIFY] Different track detected - user switched to Spotify playback")
                            # monitor_logger.debug(f"Previous: {current_track_data.get('track_name')} on {current_device}")
                            monitor_logger.info(f"Now playing on {new_device}")
                    
                    # Determine if we should update
                    major_change = (
                        track_id != self.last_track_id or
                        device_changed or
                        current_track_data is None or
                        track_data['is_playing'] != current_track_data.get('is_playing')
                    )
                    
                    # Can we take over?
                    # Spotify takeover logic:
                    # 1. No current source → take over
                    # 2. Current source has lower priority (higher number) → take over normally
                    # 3. We are already the active source (same priority) → update as needed
                    # 4. Current source has higher priority BUT (different track OR different device) → take over (user chose Spotify)
                    # 5. Current source has higher priority AND (same track AND same device) → never take over (respect priority)
                    can_take_over = False
                    if current_track_data is None:
                        # No current source, we can take over
                        can_take_over = True
                    else:
                        current_priority = current_track_data.get('source_priority', 999)
                        if current_priority > self.source_priority:
                            # We have higher priority, use normal takeover logic
                            can_take_over = self.should_source_takeover(current_track_data, time_since_last_update)
                        elif current_priority == self.source_priority:
                            # Same priority (we are the active source), can update
                            can_take_over = is_our_source
                        else:
                            # Higher priority source is active
                            # Only take over if track or device changed (already checked above)
                            # If we got here with same track and same device, we would have continued earlier
                            can_take_over = True
                    
                    # For progress updates: only send if clients need progress
                    needs_progress_update = is_our_source and self.app_state.has_clients_needing_progress()
                    
                    should_update = (major_change and can_take_over) or needs_progress_update
                    
                    if should_update:
                        self.last_track_id = track_id
                        self.last_device_name = device_name
                        self.last_update_time = current_time
                        
                        # Log source switching with detailed context
                        if major_change and (current_track_data is None or current_track_data.get('source') != 'spotify'):
                            current_source = current_track_data.get('source', 'none').upper() if current_track_data else 'NONE'
                            current_priority = current_track_data.get('source_priority', 'N/A') if current_track_data else 'N/A'
                            monitor_logger.info(f"📊 [SPOTIFY] Taking control from {current_source} (priority {current_priority})")
                            monitor_logger.debug(f"Reason: major_change={major_change}, can_take_over={can_take_over}, staleness={time_since_last_update:.1f}s")
                        
                        self.app_state.update_track_data(track_data)
                        
                        try:
                            self.socketio.emit('track_update', track_data, namespace='/')
                        except Exception:
                            pass
                        
                        # Only log major changes, not every position update
                        if major_change:
                            status = '🎵' if track_data['is_playing'] else '⏸️'
                            monitor_logger.info(f"{status} [SPOTIFY] {track_data['track_name']} - {track_data['artist']}")
                
                elif current_track_data is not None and current_track_data.get('source') == 'spotify':
                    # Only clear if current source is Spotify
                    self.app_state.update_track_data(None)
                    self.last_track_id = None
                    self.last_device_name = None
                    try:
                        self.socketio.emit('track_update', None, namespace='/')
                    except Exception:
                        pass
                    monitor_logger.info("⏹️  [SPOTIFY] No track playing")
                
                # Sleep for 2 seconds before next check
                time.sleep(2)
                
            except Exception as e:
                monitor_logger.error(f"Error in Spotify monitor loop: {e}")
                time.sleep(5)
    
    def start(self):
        """Start monitoring in background thread"""
        self._start_thread(self._monitor_loop)
        monitor_logger.info("✓ Spotify monitor started")
        return True
    
    def stop(self):
        """Stop monitoring"""
        self._stop_thread()
        monitor_logger.info("Spotify monitor stopped")
