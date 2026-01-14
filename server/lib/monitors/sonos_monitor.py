"""
Sonos Monitor
Monitors Sonos devices for playback updates
"""
import time
import threading
from typing import Optional, Dict, Any, List

from lib.monitors.base import BaseMonitor
from lib.utils import parse_time_to_ms, format_device_display
from lib.utils.logger import monitor_logger

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
        
        # Event health tracking
        self.events_active: bool = False  # Whether event subscriptions are working
        self.last_event_time: float = 0
        self.event_failure_count: int = 0
        self.max_event_failures: int = 3  # Try to recover events after 3 consecutive failures
        self.last_coordinator_check_time: float = 0  # Last time we verified coordinator subscriptions
        self.event_subscription_start_time: Optional[float] = None  # When current subscriptions were established
        
        # Connection retry tracking
        self.connection_errors: int = 0
        self.last_connection_error_time: Optional[float] = None
        self.device_unreachable_start: Optional[float] = None
        self.needs_reconnection: bool = False  # Flag to trigger device reconnection
    
    def _handle_connection_error(self, error: Exception) -> None:
        """Handle connection errors with retry logic"""
        from config import Config
        
        current_time = time.time()
        self.connection_errors += 1
        self.last_connection_error_time = current_time
        
        # Track when device first became unreachable
        if self.device_unreachable_start is None:
            self.device_unreachable_start = current_time
            monitor_logger.warning(f"⚠️  [SONOS] Device connection lost: {error}")
            monitor_logger.info(f"🔄 Starting retry attempts (every {Config.SONOS_RETRY_INTERVAL}s for up to {Config.SONOS_DEVICE_RETRY_WINDOW_TIME}s)")
            monitor_logger.info(f"   Will attempt to reconnect to all discovered Sonos devices")
        
        # Mark that we need to attempt reconnection
        self.needs_reconnection = True
        
        # Check if we've exceeded retry window
        elapsed = current_time - self.device_unreachable_start
        if elapsed > Config.SONOS_DEVICE_RETRY_WINDOW_TIME:
            monitor_logger.error(f"❌ [SONOS] Devices unreachable for {int(elapsed)}s (exceeded {Config.SONOS_DEVICE_RETRY_WINDOW_TIME}s limit)")
            monitor_logger.error(f"   Total connection errors: {self.connection_errors}")
            monitor_logger.error(f"   Marking service as unhealthy for recovery")
            self.is_ready = False
            self.events_active = False
            self.needs_reconnection = False
        else:
            remaining = Config.SONOS_DEVICE_RETRY_WINDOW_TIME - elapsed
            monitor_logger.warning(f"⚠️  [SONOS] Connection error #{self.connection_errors}: {error}")
            monitor_logger.info(f"🔄 Will retry reconnection in {Config.SONOS_RETRY_INTERVAL}s (timeout in {int(remaining)}s)")
    
    def _reset_connection_tracking(self) -> None:
        """Reset connection error tracking after successful operation"""
        if self.connection_errors > 0:
            monitor_logger.info(f"✅ [SONOS] Connection restored after {self.connection_errors} errors")
        self.connection_errors = 0
        self.last_connection_error_time = None
        self.device_unreachable_start = None
        self.needs_reconnection = False
    
    def _find_active_coordinators(self) -> List[Dict[str, Any]]:
        """Find Sonos coordinator devices (group leaders) that are currently playing"""
        coordinators = []
        
        for device_info in self.devices:
            if device_info['type'] == 'sonos':
                try:
                    device = device_info['device']
                    
                    # Only check coordinators (group leaders)
                    if not device.is_coordinator:
                        monitor_logger.debug(f"  ⏭️  Skipping {device_info['name']} (group member, not coordinator)")
                        continue
                    
                    transport = device.get_current_transport_info()
                    
                    # Check if coordinator is playing or paused (has active playback)
                    is_active = transport.get('current_transport_state') in ['PLAYING', 'PAUSED_PLAYBACK']
                    
                    if is_active:
                        device_info['transport_state'] = transport.get('current_transport_state')
                        coordinators.append(device_info)
                        monitor_logger.debug(f"  ✓ {device_info['name']} (coordinator) - {transport.get('current_transport_state')}")
                    else:
                        monitor_logger.debug(f"  ⏹️  {device_info['name']} (coordinator) - idle")
                        
                except Exception as e:
                    monitor_logger.debug(f"  ✗ Error checking {device_info['name']}: {e}")
        
        return coordinators
    
    def _attempt_reconnection(self) -> bool:
        """Attempt to reconnect to Sonos devices. Returns True if at least one coordinator is found."""
        monitor_logger.info("🔄 [SONOS] Attempting to reconnect to devices...")
        
        # Clear old subscriptions
        for sub in self.subscriptions:
            try:
                sub.unsubscribe()
            except:
                pass
        self.subscriptions.clear()
        
        # Rediscover devices
        old_device_count = len(self.devices)
        self.devices.clear()
        
        has_devices = self.discover_sonos_devices()
        
        if not has_devices:
            monitor_logger.warning(f"⚠️  [SONOS] No devices found during reconnection attempt")
            return False
        
        new_device_count = len(self.devices)
        if new_device_count != old_device_count:
            monitor_logger.info(f"ℹ️  [SONOS] Device count changed: {old_device_count} → {new_device_count}")
        
        # Find active coordinators (devices actually playing/paused with music)
        monitor_logger.info("🔍 [SONOS] Checking for active coordinators...")
        active_coordinators = self._find_active_coordinators()
        
        if not active_coordinators:
            monitor_logger.info("ℹ️  [SONOS] No coordinators with active playback found")
            # Still consider this a success - devices are available, just not playing
            self.events_active = False
            return True
        
        monitor_logger.info(f"✓ Found {len(active_coordinators)} coordinator(s) with active playback")
        
        # Subscribe only to active coordinators
        events_subscribed = False
        for device_info in active_coordinators:
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
                monitor_logger.info(f"  ✓ Subscribed to {device_info['name']} ({device_info['transport_state']})")
                events_subscribed = True
                
            except Exception as e:
                monitor_logger.warning(f"  ✗ Failed to subscribe to {device_info['name']}: {e}")
        
        if events_subscribed:
            monitor_logger.info(f"✅ [SONOS] Successfully reconnected and subscribed to {len(self.subscriptions)} coordinator(s)")
            self.events_active = True
            self.last_event_time = time.time()
            self.event_subscription_start_time = time.time()
            
            # Get current state from reconnected coordinators
            self.get_initial_state()
            
            return True
        else:
            monitor_logger.warning(f"⚠️  [SONOS] Found {len(active_coordinators)} coordinator(s) but event subscription failed")
            self.events_active = False
            return True  # Still return True since we found devices
    
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
            monitor_logger.warning(f"  ⚠️  Error getting device names: {e}")
            return [coordinator_device.player_name]
    
    def discover_sonos_devices(self) -> bool:
        """Discover Sonos speakers on network"""
        if not SONOS_AVAILABLE or soco is None:
            return False
            
        monitor_logger.info("🔍 Discovering Sonos devices...")
        try:
            devices = soco.discover(timeout=5)
            if devices:
                for device in devices:
                    monitor_logger.info(f"  ✓ Found Sonos: {device.player_name} ({device.ip_address})")
                    self.devices.append({
                        'type': 'sonos',
                        'device': device,
                        'name': device.player_name
                    })
                return True
            else:
                # monitor_logger.info(" ℹ️  No Sonos devices found")
                return False
        except Exception as e:
            monitor_logger.error(f"  ✗ Error discovering Sonos: {e}")
            return False
    
    def on_sonos_event(self, event):
        """Handle Sonos transport events (track changes, play/pause)"""
        try:
            self.last_event_time = time.time()
            self.event_failure_count = 0  # Reset failure counter on successful event
            
            if not self.events_active:
                monitor_logger.info("✅ [SONOS] Event subscriptions recovered")
                self.events_active = True
            
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
                            monitor_logger.info("📊 Progress source: SONOS (priority)")
                            monitor_logger.debug(f"   Switching from {current_track_data.get('source', 'none')} (priority {current_track_data.get('source_priority', 'N/A')}) to sonos (priority {self.source_priority})")
                        
                        self.app_state.update_track_data(track_data)
                        self.socketio.emit('track_update', track_data, namespace='/')
                        
                        status = '🎵' if track_data['is_playing'] else '⏸️'
                        monitor_logger.info(f"{status} [SONOS EVENT] {track_data['track_name']} - {track_data['artist']}")
                        
        except Exception as e:
            # Check if this is a connection error
            error_str = str(e)
            is_connection_error = any(keyword in error_str.lower() for keyword in 
                ['connection', 'refused', 'reset', 'timeout', 'unreachable', 'max retries'])
            
            if is_connection_error:
                self._handle_connection_error(e)
            else:
                monitor_logger.error(f"Error handling Sonos event: {e}")
                self.event_failure_count += 1
    
    def subscribe_to_devices(self) -> bool:
        """Subscribe to events from coordinator devices only"""
        if not self.devices:
            return False
            
        monitor_logger.info("📡 Subscribing to device events...")
        
        for device_info in self.devices:
            if device_info['type'] == 'sonos':
                try:
                    device = device_info['device']
                    
                    # Only subscribe to coordinators (group leaders have the playback state)
                    if not device.is_coordinator:
                        monitor_logger.debug(f"  ⏭️  Skipping {device_info['name']} (group member)")
                        continue
                    
                    # Subscribe to AVTransport events (play/pause/track change)
                    sub = device.avTransport.subscribe(auto_renew=True)
                    
                    # Store device name and reference for event handler
                    sub.service.device_name = device_info['name']
                    sub.service.soco = device
                    
                    # Set callback
                    sub.callback = self.on_sonos_event
                    
                    self.subscriptions.append(sub)
                    monitor_logger.info(f"  ✓ Subscribed to {device_info['name']} (coordinator)")
                    
                except Exception as e:
                    monitor_logger.warning(f"  ✗ Failed to subscribe to {device_info['name']}: {e}")
        
        if len(self.subscriptions) > 0:
            self.event_subscription_start_time = time.time()
        
        return len(self.subscriptions) > 0
    
    def get_initial_state(self) -> Optional[Dict[str, Any]]:
        """Get current playback state from coordinator devices only"""
        for device_info in self.devices:
            if device_info['type'] == 'sonos':
                try:
                    device = device_info['device']
                    
                    # Only check coordinators - they have the actual playback state
                    if not device.is_coordinator:
                        continue
                    
                    transport = device.get_current_transport_info()
                    
                    # Skip if not actively playing/paused
                    if transport.get('current_transport_state') not in ['PLAYING', 'PAUSED_PLAYBACK']:
                        continue
                    
                    track = device.get_current_track_info()
                    
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
                        
                        # Check if we should take over from current source
                        current_track = self.app_state.get_track_data()
                        should_takeover = (
                            not current_track or
                            current_track.get('source_priority', 999) > self.source_priority
                        )
                        
                        if should_takeover:
                            self.app_state.update_track_data(track_data)
                            self.last_track_id = self.create_track_identifier(track_data)
                            self.last_update_time = time.time()
                            
                            # Format device names for logging
                            device_display = format_device_display(device_names)
                            state = "▶️  PLAYING" if track_data['is_playing'] else "⏸️  PAUSED"
                            monitor_logger.info(f"  ℹ️  Initial state ({state}): {track_data['track_name']} - {track_data['artist']}")
                            monitor_logger.info(f"  📱 Playing on: {device_display}")
                            
                            if current_track and current_track.get('source') != 'sonos':
                                monitor_logger.info(f"  📊 Taking over from {current_track.get('source', 'unknown').upper()} (Sonos priority)")
                        else:
                            # Don't take over, but store for later takeover check
                            state = "▶️  PLAYING" if track_data['is_playing'] else "⏸️  PAUSED"
                            monitor_logger.info(f"  ℹ️  Sonos detected ({state}): {track_data['track_name']} - {track_data['artist']}")
                            monitor_logger.info(f"  ⏸️  Not taking over (current source has higher priority)")
                        
                        return track_data
                        
                except Exception as e:
                    monitor_logger.warning(f"  ⚠️  Error getting initial state from {device_info['name']}: {e}")
        
        monitor_logger.info("  ℹ️  No coordinators currently playing music")
        return None
    
    def _poll_position_updates(self):
        """
        Continuously poll for position updates.
        Also monitors event health and handles full state updates when events fail.
        Additionally checks if Sonos should take over from lower-priority sources.
        """
        from config import Config
        
        while self.is_running:
            try:
                # Check if we need to attempt reconnection
                if self.needs_reconnection:
                    from config import Config
                    
                    # Check if we're still within retry window
                    if self.device_unreachable_start:
                        elapsed = time.time() - self.device_unreachable_start
                        if elapsed <= Config.SONOS_DEVICE_RETRY_WINDOW_TIME:
                            # Wait before retry
                            time.sleep(Config.SONOS_RETRY_INTERVAL)
                            
                            # Attempt reconnection to all devices
                            success = self._attempt_reconnection()
                            
                            if success:
                                # At least one device connected successfully
                                self._reset_connection_tracking()
                                monitor_logger.info("✅ [SONOS] Device reconnection successful, resuming normal operation")
                            else:
                                # Reconnection failed, will retry on next iteration
                                remaining = Config.SONOS_DEVICE_RETRY_WINDOW_TIME - elapsed
                                if remaining <= 60:
                                    time_str = f"{int(remaining)}s"
                                else:
                                    time_str = f"{remaining / 60:.1f}min"
                                monitor_logger.warning(f"⚠️  [SONOS] Reconnection attempt failed, will retry... (timeout in {time_str})")
                        else:
                            # Exceeded retry window, mark as failed
                            self._handle_connection_error(Exception("Retry window exceeded"))
                    
                    continue
                
                # OPTIMIZATION: Check if higher-priority source is active BEFORE polling
                # This reduces unnecessary operations when a higher-priority service is playing
                # (e.g., if Apple Music has priority 0, Sonos would reduce its activity)
                if self.should_use_reduced_polling(self.app_state, Config.SPOTIFY_TAKEOVER_WAIT_TIME):
                    current_track_data = self.app_state.get_track_data()
                    # monitor_logger.debug(f"[SONOS] Higher-priority source ({current_track_data.get('source')}) active, using reduced polling")
                    time.sleep(Config.SONOS_REDUCED_POLLING_INTERVAL)
                    continue
                
                time.sleep(Config.SONOS_CHECK_TAKEOVER_INTERVAL)
                
                current_track_data = self.app_state.get_track_data()
                current_time = time.time()
                
                # Check for stale event subscriptions
                # Events should fire on track changes and play/pause state changes
                # If Sonos is playing but we haven't received events for too long, subscriptions may have died
                sonos_is_active_source = current_track_data and current_track_data.get('source') == 'sonos'
                time_since_last_event = current_time - self.last_event_time if self.last_event_time > 0 else 0
                subscription_age = current_time - self.event_subscription_start_time if self.event_subscription_start_time else 999999
                
                # Detect stale events: subscriptions are marked active but no events received recently
                # AND we've given subscriptions enough time to establish (at least 10 seconds)
                events_appear_stale = (
                    self.events_active and
                    subscription_age > 10 and
                    time_since_last_event > Config.SONOS_EVENT_STALENESS_THRESHOLD
                )
                
                if events_appear_stale:
                    monitor_logger.warning(f"⚠️  [SONOS] Event subscriptions appear stale (no events for {int(time_since_last_event)}s)")
                    monitor_logger.warning(f"   Subscription age: {int(subscription_age)}s, Last event: {int(time_since_last_event)}s ago")
                    monitor_logger.info("🔄 [SONOS] Attempting to resubscribe to events...")
                    
                    # Mark events as inactive and trigger resubscription
                    self.events_active = False
                    
                    # Try to resubscribe
                    success = self._attempt_reconnection()
                    if success:
                        monitor_logger.info("✅ [SONOS] Event subscriptions re-established")
                        self._reset_connection_tracking()
                    else:
                        monitor_logger.warning("⚠️  [SONOS] Resubscription failed, will retry...")
                        # Set needs_reconnection to trigger retry on next loop
                        self.needs_reconnection = True
                        self.device_unreachable_start = current_time
                
                # Always poll for position when Sonos is active source and clients need it
                should_poll_position = (
                    current_track_data and 
                    current_track_data.get('source') == 'sonos' and
                    self.app_state.has_clients_needing_progress()
                )
                
                # Poll for full state when events failed at subscription time
                # (not based on event frequency - events only fire on state changes)
                should_poll_full_state = (
                    current_track_data and 
                    current_track_data.get('source') == 'sonos' and
                    not self.events_active
                )
                
                # Send heartbeat updates to keep timestamp fresh (prevent other sources from thinking Sonos is stale)
                # This runs when Sonos is the active source but clients don't need progress updates
                should_send_heartbeat = (
                    current_track_data and 
                    current_track_data.get('source') == 'sonos' and
                    not self.app_state.has_clients_needing_progress() and
                    self.events_active and
                    time.time() - current_track_data.get('timestamp', 0) > Config.SONOS_HEARTBEAT_INTERVAL
                )
                
                # Check if Sonos should take over from lower-priority source
                # This handles the case where Sonos recovers while another source is active
                should_check_takeover = (
                    current_track_data and
                    current_track_data.get('source') != 'sonos' and
                    current_track_data.get('source_priority', 999) > self.source_priority
                )
                
                if should_poll_position or should_poll_full_state or should_check_takeover or should_send_heartbeat:
                    # Handle heartbeat - verify Sonos is still playing before updating timestamp
                    if should_send_heartbeat:
                        # Query device to verify it's still playing before sending heartbeat
                        for device_info in self.devices:
                            if device_info['type'] == 'sonos':
                                try:
                                    device = device_info['device']
                                    
                                    # Only check coordinators (they have the actual playback state)
                                    if not device.is_coordinator:
                                        continue
                                    
                                    transport = device.get_current_transport_info()
                                    is_playing = transport.get('current_transport_state') == 'PLAYING'
                                    
                                    if is_playing:
                                        # Sonos is still playing - update timestamp
                                        fresh_track_data = self.app_state.get_track_data()
                                        if fresh_track_data and fresh_track_data.get('source') == 'sonos':
                                            fresh_track_data['timestamp'] = time.time()
                                            self.app_state.update_track_data(fresh_track_data)
                                    else:
                                        # Not playing - let timestamp go stale so other sources can take over
                                        # Clear track if Sonos was the source
                                        fresh_track_data = self.app_state.get_track_data()
                                        if fresh_track_data and fresh_track_data.get('source') == 'sonos' and not fresh_track_data.get('is_playing'):
                                            monitor_logger.info("⏹️  [SONOS] Playback stopped, clearing track")
                                            self.app_state.update_track_data(None)
                                            try:
                                                self.socketio.emit('track_update', None, namespace='/')
                                            except Exception:
                                                pass
                                    
                                    # Reset connection error tracking on successful operation
                                    self._reset_connection_tracking()
                                    
                                    break  # Only need to check one device
                                except Exception as e:
                                    error_str = str(e)
                                    is_connection_error = any(keyword in error_str.lower() for keyword in 
                                        ['connection', 'refused', 'reset', 'timeout', 'unreachable', 'max retries'])
                                    
                                    if is_connection_error:
                                        self._handle_connection_error(e)
                                    else:
                                        monitor_logger.warning(f"⚠️  [SONOS] Heartbeat check error: {e}")
                    
                    # For other conditions, we need to query the device
                    if should_poll_position or should_poll_full_state or should_check_takeover:
                        for device_info in self.devices:
                            if device_info['type'] == 'sonos':
                                try:
                                    device = device_info['device']
                                    
                                    # Only check coordinators (they have the actual playback state)
                                    if not device.is_coordinator:
                                        continue
                                    
                                    track = device.get_current_track_info()
                                    transport = device.get_current_transport_info()
                                    
                                    if track and track.get('title'):
                                        position_ms = parse_time_to_ms(track.get('position', '0:00:00'))
                                        duration_ms = parse_time_to_ms(track.get('duration', '0:00:00'))
                                        is_playing = transport.get('current_transport_state') == 'PLAYING'
                                        
                                        # Check if Sonos should take over from lower-priority source
                                        if should_check_takeover and is_playing:
                                            track_id = f"{track.get('title')}_{track.get('artist')}"
                                            device_names = self.get_device_names(device)
                                            
                                            # Check if it's the same track
                                            current_track_id = f"{current_track_data.get('track_name', '')}_{current_track_data.get('artist', '')}" if current_track_data else ""
                                            is_same_track = track_id == current_track_id
                                            
                                            new_track_data = {
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
                                            
                                            self.last_track_id = track_id
                                            self.last_update_time = time.time()
                                            self.app_state.update_track_data(new_track_data)
                                            self.socketio.emit('track_update', new_track_data, namespace='/')
                                            
                                            current_source = current_track_data.get('source', 'unknown').upper()
                                            current_priority = current_track_data.get('source_priority', 999)
                                            same_track_note = " (same track)" if is_same_track else " (different track)"
                                            monitor_logger.info(f"📊 Progress source: SONOS (priority)")
                                            monitor_logger.info(f"   Taking over from {current_source} (priority {current_priority}){same_track_note}")
                                            monitor_logger.info(f"🎵 [SONOS] {new_track_data['track_name']} - {new_track_data['artist']}")
                                        
                                        # If events are down, check for track changes
                                        if should_poll_full_state:
                                            track_id = f"{track.get('title')}_{track.get('artist')}"
                                            
                                            if self.last_track_id != track_id:
                                                monitor_logger.info(f"🔄 [SONOS POLL] Track changed: {track.get('title')} - {track.get('artist')}")
                                                self.last_track_id = track_id
                                                
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
                                        
                                        # Always update position (whether events are working or not)
                                        # Get fresh track data to avoid race condition with events
                                        fresh_track_data = self.app_state.get_track_data()
                                        if fresh_track_data and fresh_track_data.get('source') == 'sonos':
                                            fresh_track_data['progress_ms'] = position_ms
                                            fresh_track_data['duration_ms'] = duration_ms
                                            fresh_track_data['is_playing'] = is_playing
                                            fresh_track_data['timestamp'] = time.time()
                                            
                                            self.app_state.update_track_data(fresh_track_data)
                                            self.socketio.emit('track_update', fresh_track_data, namespace='/')
                                        
                                        # Reset connection error tracking on successful operation
                                        self._reset_connection_tracking()
                                        break  # Only need to poll one device
                                    
                                except Exception as e:
                                    error_str = str(e)
                                    is_connection_error = any(keyword in error_str.lower() for keyword in 
                                        ['connection', 'refused', 'reset', 'timeout', 'unreachable', 'max retries'])
                                    
                                    if is_connection_error:
                                        self._handle_connection_error(e)
                                        # Don't wait here - let the reconnection logic at top of loop handle timing
                                    else:
                                        monitor_logger.warning(f"⚠️  [SONOS] Polling error: {e}")
                                
            except Exception as e:
                monitor_logger.error(f"⚠️  [SONOS] Position polling loop error: {e}")
    
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
                monitor_logger.warning("⚠️  No Sonos devices found on network")
                self.is_running = False
                return False
            
            # Try to subscribe to events
            events_subscribed = self.subscribe_to_devices()
            if events_subscribed:
                monitor_logger.info("✅ Event subscriptions active (track changes & playback state)")
                self.events_active = True
                self.last_event_time = time.time()
                self.event_subscription_start_time = time.time()
            else:
                monitor_logger.warning("⚠️  Event subscriptions failed, using polling only")
                self.events_active = False
                self.event_subscription_start_time = None
            
            # Get initial state
            self.get_initial_state()
            
            # Always start polling (handles position updates + event fallback)
            self.polling_thread = threading.Thread(target=self._poll_position_updates, daemon=True)
            self.polling_thread.start()
            
            self.is_ready = True
            mode = "events + polling" if events_subscribed else "polling only"
            monitor_logger.info(f"✅ Sonos monitoring started - Mode: {mode}")
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
        monitor_logger.info("Sonos monitoring stopped")
