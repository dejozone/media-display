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
        stale_threshold: float = 10.0
    ) -> bool:
        """
        Determine if this source should take over from current source
        
        Args:
            current_track_data: Current track data from active source
            time_since_update: Seconds since last update from current source
            stale_threshold: Seconds before source is considered stale
            
        Returns:
            bool: True if this source should take over
        """
        if not current_track_data:
            return True
        
        current_priority = current_track_data.get('source_priority', 999)
        has_higher_priority = current_priority > self.source_priority
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
