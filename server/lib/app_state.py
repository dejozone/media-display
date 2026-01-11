"""
Application State Management
Centralized state management for the Now Playing Server
"""
import threading
from typing import Optional, Dict, Any, Set, List
from lib.monitors.base import BaseMonitor


class AppState:
    """Centralized application state"""
    
    def __init__(self):
        self.current_track_data: Optional[Dict[str, Any]] = None
        self.connected_clients: int = 0
        self.active_monitors: List[BaseMonitor] = []
        self.clients_needing_progress: Set[str] = set()
        self.desired_services: Set[str] = set()
        self.recovery_running: bool = False
        self.recovery_thread: Optional[threading.Thread] = None
        
        # Lock for thread-safe operations
        self._lock = threading.Lock()
    
    def add_monitor(self, monitor: BaseMonitor) -> None:
        """Add a monitor to the active monitors list"""
        with self._lock:
            self.active_monitors.append(monitor)
    
    def remove_monitor(self, monitor_type: type) -> None:
        """Remove monitors of a specific type"""
        with self._lock:
            self.active_monitors = [m for m in self.active_monitors if not isinstance(m, monitor_type)]
    
    def get_monitor(self, monitor_type: type) -> Optional[BaseMonitor]:
        """Get the first monitor of a specific type"""
        with self._lock:
            for monitor in self.active_monitors:
                if isinstance(monitor, monitor_type):
                    return monitor
        return None
    
    def is_service_active(self, service_name: str) -> bool:
        """Check if a specific service is currently active"""
        with self._lock:
            if service_name == 'sonos':
                from lib.monitors.sonos_monitor import SonosMonitor
                return any(isinstance(m, SonosMonitor) and m.is_ready and m.is_running for m in self.active_monitors)
            elif service_name == 'spotify':
                from lib.monitors.spotify_monitor import SpotifyMonitor
                return any(isinstance(m, SpotifyMonitor) and m.is_ready and m.is_running for m in self.active_monitors)
        return False
    
    def get_active_services(self) -> Dict[str, bool]:
        """Get dictionary of currently active services"""
        with self._lock:
            from lib.monitors.sonos_monitor import SonosMonitor
            from lib.monitors.spotify_monitor import SpotifyMonitor
            return {
                'sonos': any(isinstance(m, SonosMonitor) and m.is_ready and m.is_running for m in self.active_monitors),
                'spotify': any(isinstance(m, SpotifyMonitor) and m.is_ready and m.is_running for m in self.active_monitors)
            }
    
    def add_client_needing_progress(self, client_id: str) -> bool:
        """
        Add a client to progress tracking
        
        Returns:
            bool: True if this is the first client needing progress
        """
        with self._lock:
            was_empty = len(self.clients_needing_progress) == 0
            self.clients_needing_progress.add(client_id)
            return was_empty
    
    def remove_client_needing_progress(self, client_id: str) -> bool:
        """
        Remove a client from progress tracking
        
        Returns:
            bool: True if no more clients need progress
        """
        with self._lock:
            self.clients_needing_progress.discard(client_id)
            return len(self.clients_needing_progress) == 0
    
    def has_clients_needing_progress(self) -> bool:
        """Check if any clients need progress updates"""
        with self._lock:
            return len(self.clients_needing_progress) > 0
    
    def increment_clients(self) -> int:
        """Increment connected clients count and return new count"""
        with self._lock:
            self.connected_clients += 1
            return self.connected_clients
    
    def decrement_clients(self) -> int:
        """Decrement connected clients count and return new count"""
        with self._lock:
            self.connected_clients = max(0, self.connected_clients - 1)
            return self.connected_clients
    
    def update_track_data(self, track_data: Optional[Dict[str, Any]]) -> None:
        """Update current track data"""
        with self._lock:
            self.current_track_data = track_data
    
    def get_track_data(self) -> Optional[Dict[str, Any]]:
        """Get current track data"""
        with self._lock:
            return self.current_track_data
    
    def cleanup(self) -> None:
        """Cleanup all resources"""
        # Stop recovery thread
        self.recovery_running = False
        if self.recovery_thread:
            try:
                self.recovery_thread.join(timeout=2)
            except:
                pass
        
        # Stop all monitors
        with self._lock:
            for monitor in self.active_monitors:
                try:
                    monitor.stop()
                except:
                    pass
