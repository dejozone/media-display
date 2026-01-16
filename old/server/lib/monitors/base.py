"""
Base Monitor Abstract Class
Provides common functionality for all media monitors
"""
from abc import ABC, abstractmethod
import threading
from typing import Optional, Dict, Any


class BaseMonitor(ABC):
    """Abstract base class for media monitors (Sonos, Spotify, etc.)"""
    
    def __init__(self, source_priority: int):
        """
        Initialize base monitor
        
        Args:
            source_priority: Lower number = higher priority (Sonos=1, Spotify=2)
        """
        self.is_running = False
        self.is_ready = False
        self.last_track_id: Optional[str] = None
        self.last_update_time = 0
        self.source_priority = source_priority
        self.monitor_thread: Optional[threading.Thread] = None
        
        # Source-specific takeover timeout
        self.takeover_timeout = self._get_takeover_timeout()
    
    def _get_takeover_timeout(self) -> int:
        """
        Get takeover timeout based on source type.
        Sonos has network group sync delays and needs more time.
        
        Returns:
            int: Timeout in seconds before source is considered stale
        """
        # Check if this is a Sonos monitor (needs more time for group sync)
        if 'Sonos' in self.__class__.__name__:
            return 30  # 30 seconds for Sonos (accounts for multi-speaker sync delays)
        return 10  # 10 seconds for other sources (Spotify, etc.)
    
    @abstractmethod
    def start(self) -> bool:
        """
        Start monitoring - returns True if successful
        
        Returns:
            bool: True if monitor started successfully
        """
        pass
    
    @abstractmethod
    def stop(self):
        """Stop monitoring and cleanup resources"""
        pass
    
    @abstractmethod
    def get_current_playback(self) -> Optional[Dict[str, Any]]:
        """
        Get current playback state
        
        Returns:
            Optional[Dict]: Track data if playing, None otherwise
        """
        pass
    
    def _start_thread(self, target, daemon: bool = True):
        """
        Helper to start monitoring thread
        
        Args:
            target: Target function for thread
            daemon: Whether thread should be daemon (default: True)
        """
        if not self.is_running:
            self.is_running = True
            self.monitor_thread = threading.Thread(target=target, daemon=daemon)
            self.monitor_thread.start()
            self.is_ready = True
    
    def should_use_reduced_polling(self, app_state, takeover_wait_time: int) -> bool:
        """
        Check if a higher-priority source is active and fresh.
        If so, this monitor should use reduced polling to avoid unnecessary operations.
        
        This method can be used by any monitor (Sonos, Spotify, Apple Music, etc.)
        to determine if it should poll less frequently.
        
        Args:
            app_state: Application state object
            takeover_wait_time: Seconds to wait before considering source stale
        
        Returns:
            bool: True if should use reduced polling (higher-priority source is fresh)
        """
        import time
        
        current_track_data = app_state.get_track_data()
        
        # No current source - use normal polling
        if not current_track_data:
            return False
        
        # Higher-priority source is active
        if current_track_data.get('source_priority', 999) < self.source_priority:
            time_since_last_update = time.time() - current_track_data.get('timestamp', 0)
            
            # Higher-priority source is fresh - use reduced polling
            if time_since_last_update < takeover_wait_time:
                return True
        
        return False
    
    def _stop_thread(self, timeout: int = 5):
        """
        Helper to stop monitoring thread
        
        Args:
            timeout: Maximum seconds to wait for thread to stop
        """
        self.is_ready = False
        self.is_running = False
        if self.monitor_thread and self.monitor_thread.is_alive():
            self.monitor_thread.join(timeout=timeout)
    
    def should_source_takeover(
        self,
        current_track_data: Optional[Dict[str, Any]],
        time_since_update: float,
        stale_threshold: Optional[float] = None  # Now optional, uses source-specific timeout
    ) -> bool:
        """
        Determine if this source should take over from current source
        
        Args:
            current_track_data: Current track data from active source
            time_since_update: Seconds since last update from current source
            stale_threshold: Optional override for staleness threshold (uses source-specific timeout if None)
            
        Returns:
            bool: True if this source should take over
        """
        if not current_track_data:
            return True
        
        current_priority = current_track_data.get('source_priority', 999)
        has_higher_priority = current_priority > self.source_priority
        
        # Determine staleness threshold
        # If current source is Sonos, it needs more time due to group sync delays
        if stale_threshold is None:
            current_source = current_track_data.get('source', '')
            if current_source == 'sonos':
                stale_threshold = 60  # Give Sonos more time for group sync
            else:
                stale_threshold = 10  # Standard timeout for other sources
        
        is_stale = time_since_update > stale_threshold
        
        return has_higher_priority or is_stale
    
    def create_track_identifier(self, track_data: Dict[str, Any]) -> str:
        """
        Create consistent track identifier across sources
        
        Args:
            track_data: Track data dictionary
            
        Returns:
            str: Unique identifier for the track
        """
        return f"{track_data['track_name']}_{track_data['artist']}"
