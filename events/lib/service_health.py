"""Service health tracking for backend services like Sonos."""

import asyncio
import logging
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Dict, Optional


class ServiceStatus(str, Enum):
    """Health status of a service."""
    HEALTHY = "healthy"
    DEGRADED = "degraded"
    RECOVERING = "recovering"
    UNAVAILABLE = "unavailable"


class ErrorCode(str, Enum):
    """Error codes for service health issues."""
    NO_DEVICES = "no_devices"
    NETWORK_ERROR = "network_error"
    SUBSCRIPTION_FAILED = "subscription_failed"
    DEVICE_REBOOTING = "device_rebooting"
    DEVICE_UPDATING = "device_updating"
    COORDINATOR_ERROR = "coordinator_error"
    AUTH_ERROR = "auth_error"
    TIMEOUT = "timeout"
    RATE_LIMITED = "rate_limited"  # Spotify-specific: API rate limit hit
    SERVER_ERROR = "server_error"  # Spotify-specific: 5xx errors
    UNKNOWN = "unknown"


# Retry timing configuration (seconds)
RETRY_TIMING = {
    ErrorCode.NO_DEVICES: 15,
    ErrorCode.NETWORK_ERROR: 10,
    ErrorCode.SUBSCRIPTION_FAILED: 10,
    ErrorCode.DEVICE_REBOOTING: 45,
    ErrorCode.DEVICE_UPDATING: 120,
    ErrorCode.COORDINATOR_ERROR: 10,
    ErrorCode.AUTH_ERROR: 0,  # No retry, requires user action
    ErrorCode.TIMEOUT: 15,
    ErrorCode.RATE_LIMITED: 30,  # Spotify rate limit, use Retry-After header if available
    ErrorCode.SERVER_ERROR: 20,
    ErrorCode.UNKNOWN: 20,
}

# Default debounce window for health status messages (seconds)
DEFAULT_HEALTH_STATUS_WINDOW_SEC = 30


@dataclass
class ServiceHealthState:
    """Tracks the health state of a service."""
    
    provider: str
    status: ServiceStatus = ServiceStatus.HEALTHY
    error_code: Optional[ErrorCode] = None
    message: Optional[str] = None
    devices_count: int = 0
    consecutive_errors: int = 0
    last_healthy_at: Optional[float] = None
    recovery_started_at: Optional[float] = None
    max_status_emits: int = 3  # max error status messages before entering silent health-check mode
    emit_suppressed: bool = False  # when True, only recovery/healthy statuses are sent
    # Debounce tracking
    _last_sent_status: Optional[ServiceStatus] = field(default=None, repr=False)
    _last_sent_error_code: Optional[ErrorCode] = field(default=None, repr=False)
    _first_unhealthy_time: Optional[float] = field(default=None, repr=False)  # When errors started
    _health_status_window_sec: float = field(default=DEFAULT_HEALTH_STATUS_WINDOW_SEC, repr=False)
    _lock: asyncio.Lock = field(default_factory=asyncio.Lock, repr=False)
    
    def __post_init__(self):
        if self.last_healthy_at is None:
            self.last_healthy_at = time.time()
    
    def reset_debounce(self) -> None:
        """Reset the debounce state for a fresh client connection.
        
        This ensures the first status message is always sent to a new/reconnecting client.
        Does NOT reset the actual health state - we want to report the real current state.
        """
        self._last_sent_status = None
        self._last_sent_error_code = None
        self._first_unhealthy_time = None
    
    def set_health_status_window(self, window_sec: float) -> None:
        """Set the debounce window for health status messages."""
        self._health_status_window_sec = window_sec

    def set_status_emit_limit(self, emit_limit: int) -> None:
        """Set how many error statuses to emit before going quiet and only probing."""
        if emit_limit > 0:
            self.max_status_emits = emit_limit
    
    def _get_retry_sec(self, error_code: ErrorCode) -> int:
        """Get retry timing for an error code."""
        return RETRY_TIMING.get(error_code, 20)
    
    def _should_fallback(self, error_code: ErrorCode) -> bool:
        """Determine if client should fallback to another service."""
        # Always fallback except for transient errors that resolve quickly
        return error_code not in {ErrorCode.SUBSCRIPTION_FAILED}
    
    def _should_send_status(self, new_status: ServiceStatus, new_error_code: Optional[ErrorCode]) -> bool:
        """Check if status should be sent based on window and change rules.
        
        Rules:
        1. Always send on status change (HEALTHY -> RECOVERING, RECOVERING -> UNAVAILABLE, etc.)
        2. Always send on error code change (even within same status)
        3. Within sendHealthStatusWindowSec from first error: send all messages (client needs initial state)
        4. After window: only send on actual changes (rules 1 & 2)
        """
        now = time.time()

        # If we've entered suppression, only allow recovery/healthy to be sent
        if self.emit_suppressed and new_status != ServiceStatus.HEALTHY:
            return False
        
        # Always send on status change
        if new_status != self._last_sent_status:
            return True
        
        # Always send on error code change
        if new_error_code != self._last_sent_error_code:
            return True
        
        # Within initial window from first unhealthy: continue sending
        # This helps client establish initial state
        if self._first_unhealthy_time is not None:
            time_since_first_error = now - self._first_unhealthy_time
            if time_since_first_error < self._health_status_window_sec:
                return True
        
        # After window: only status/error changes (handled above) trigger send
        return False
    
    def _mark_status_sent(self, new_status: ServiceStatus, new_error_code: Optional[ErrorCode]) -> None:
        """Mark that a status message was sent (for debounce tracking)."""
        now = time.time()
        
        # Track when errors first started (for window calculation)
        if new_status != ServiceStatus.HEALTHY:
            if self._first_unhealthy_time is None:
                self._first_unhealthy_time = now
        else:
            # Reset when healthy
            self._first_unhealthy_time = None
        
        self._last_sent_status = new_status
        self._last_sent_error_code = new_error_code
    
    async def on_error(self, error_code: ErrorCode, message: Optional[str] = None) -> Optional[Dict[str, Any]]:
        """Record an error and return status message for client (or None if debounced)."""
        async with self._lock:
            self.consecutive_errors += 1
            self.error_code = error_code
            self.message = message
            
            # Determine status based on error type and consecutive errors
            if error_code == ErrorCode.AUTH_ERROR:
                self.status = ServiceStatus.UNAVAILABLE
            elif self.consecutive_errors >= 3:
                self.status = ServiceStatus.UNAVAILABLE
            else:
                self.status = ServiceStatus.RECOVERING
                if self.recovery_started_at is None:
                    self.recovery_started_at = time.time()

            # After exceeding the emit limit, enter suppression (quiet) mode
            if self.consecutive_errors > self.max_status_emits:
                self.emit_suppressed = True
            
            # Check if we should send this status (debounce)
            if not self._should_send_status(self.status, error_code):
                return None
            
            self._mark_status_sent(self.status, error_code)
            retry_sec = self._get_retry_sec(error_code)
            should_fallback = self._should_fallback(error_code)
            
            return self._build_status_message(retry_sec, should_fallback)
    
    async def on_degraded(self, devices_found: int, devices_expected: int, message: Optional[str] = None) -> Optional[Dict[str, Any]]:
        """Record degraded state (partial functionality). Returns None if debounced."""
        async with self._lock:
            self.status = ServiceStatus.DEGRADED
            self.devices_count = devices_found
            self.message = message or f"Found {devices_found} of {devices_expected} expected devices"
            self.error_code = None
            # Don't increment consecutive_errors for degraded state
            
            # Check if we should send this status (debounce)
            if not self._should_send_status(self.status, None):
                return None
            
            self._mark_status_sent(self.status, None)
            return self._build_status_message(retry_sec=30, should_fallback=False)
    
    async def on_recovery(self, devices_count: int = 0) -> Optional[Dict[str, Any]]:
        """Record successful recovery. Returns None if debounced (unlikely for recovery)."""
        async with self._lock:
            was_unhealthy = self.status != ServiceStatus.HEALTHY
            self.status = ServiceStatus.HEALTHY
            self.error_code = None
            self.message = None
            self.consecutive_errors = 0
            self.emit_suppressed = False
            self.devices_count = devices_count
            self.last_healthy_at = time.time()
            self.recovery_started_at = None
            
            # Check if we should send this status (debounce)
            # Note: Recovery to healthy will almost always be sent due to status change
            if not self._should_send_status(self.status, None):
                return None
            
            self._mark_status_sent(self.status, None)
            return self._build_status_message(retry_sec=0, should_fallback=False)
    
    def _build_status_message(self, retry_sec: int, should_fallback: bool) -> Dict[str, Any]:
        """Build a standardized status message for the client.
        
        This method ensures a consistent message structure for all services (Sonos, Spotify, etc.).
        
        Message structure:
        {
            "type": "service_status",           # Fixed value for all health messages
            "provider": str,                    # "sonos" or "spotify"
            "status": str,                      # "healthy", "degraded", "recovering", "unavailable"
            "error_code": str | None,           # Error code like "no_devices", "rate_limited", etc.
            "message": str | None,              # Human-readable error message
            "devices_count": int,               # Number of devices (0 for non-device services like Spotify)
            "retry_in_sec": int,                # Suggested retry timing in seconds
            "should_fallback": bool,            # Whether client should fallback to another service
            "last_healthy_at": float | None,    # Unix timestamp of last healthy state
        }
        """
        return {
            "type": "service_status",
            "provider": self.provider,
            "status": self.status.value,
            "error_code": self.error_code.value if self.error_code else None,
            "message": self.message,
            "devices_count": self.devices_count,
            "retry_in_sec": retry_sec,
            "should_fallback": should_fallback,
            "last_healthy_at": self.last_healthy_at,
        }
    
    def get_current_status(self) -> Dict[str, Any]:
        """Get current status without changing state."""
        retry_sec = self._get_retry_sec(self.error_code) if self.error_code else 0
        should_fallback = self._should_fallback(self.error_code) if self.error_code else False
        return self._build_status_message(retry_sec, should_fallback)


class ServiceHealthTracker:
    """Tracks health status of all services."""
    
    def __init__(self, config: Optional[Dict[str, Any]] = None):
        """Initialize the tracker.
        
        Args:
            config: Optional config dict with provider-specific settings.
                    Expected format: {"sonos": {"sendHealthStatusWindowSec": 30}, ...}
        """
        self._services: Dict[str, ServiceHealthState] = {}
        self._config = config or {}
        self._logger = logging.getLogger("events.health")
    
    def configure(self, config: Dict[str, Any]) -> None:
        """Update configuration for health status windows.
        
        Args:
            config: Config dict with provider-specific settings.
                    Expected format: {"sonos": {"sendHealthStatusWindowSec": 30}, ...}
        """
        self._config = config
        # Update existing services with new config
        for provider, state in self._services.items():
            provider_cfg = self._config.get(provider, {})
            window_sec = provider_cfg.get("sendHealthStatusWindowSec", DEFAULT_HEALTH_STATUS_WINDOW_SEC)
            emit_limit = provider_cfg.get("numOfEmitStatusRetries", 3)
            state.set_health_status_window(window_sec)
            state.set_status_emit_limit(emit_limit)
    
    def get_or_create(self, provider: str) -> ServiceHealthState:
        """Get or create a health state tracker for a provider."""
        if provider not in self._services:
            state = ServiceHealthState(provider=provider)
            # Apply config for this provider
            provider_cfg = self._config.get(provider, {})
            window_sec = provider_cfg.get("sendHealthStatusWindowSec", DEFAULT_HEALTH_STATUS_WINDOW_SEC)
            emit_limit = provider_cfg.get("numOfEmitStatusRetries", 3)
            state.set_health_status_window(window_sec)
            state.set_status_emit_limit(emit_limit)
            self._services[provider] = state
        return self._services[provider]
    
    async def report_error(self, provider: str, error_code: ErrorCode, message: Optional[str] = None) -> Optional[Dict[str, Any]]:
        """Report an error for a service. Returns None if debounced."""
        state = self.get_or_create(provider)
        result = await state.on_error(error_code, message)
        # Only log if the status will be sent (not debounced)
        if result is not None:
            self._logger.warning(f"Service {provider} error: {error_code.value} - {message}")
        return result
    
    async def report_degraded(
        self, 
        provider: str, 
        devices_found: int, 
        devices_expected: int, 
        message: Optional[str] = None
    ) -> Optional[Dict[str, Any]]:
        """Report degraded state for a service. Returns None if debounced."""
        state = self.get_or_create(provider)
        result = await state.on_degraded(devices_found, devices_expected, message)
        # Only log if the status will be sent (not debounced)
        if result is not None:
            self._logger.info(f"Service {provider} degraded: {devices_found}/{devices_expected} devices")
        return result
    
    async def report_healthy(self, provider: str, devices_count: int = 0) -> Optional[Dict[str, Any]]:
        """Report recovery/healthy state for a service. Returns None if debounced."""
        state = self.get_or_create(provider)
        was_unhealthy = state.status != ServiceStatus.HEALTHY
        result = await state.on_recovery(devices_count)
        # Only log if the status will be sent (not debounced) and was previously unhealthy
        if result is not None and was_unhealthy:
            self._logger.info(f"Service {provider} recovered with {devices_count} devices")
        return result
    
    def get_status(self, provider: str) -> Optional[Dict[str, Any]]:
        """Get current status for a service."""
        state = self._services.get(provider)
        if state:
            return state.get_current_status()
        return None
    
    def is_healthy(self, provider: str) -> bool:
        """Check if a service is healthy."""
        state = self._services.get(provider)
        if not state:
            return True  # Unknown services assumed healthy
        return state.status == ServiceStatus.HEALTHY

    def is_suppressed(self, provider: str) -> bool:
        """Check if a provider has stopped emitting after exceeding its error emit limit."""
        state = self._services.get(provider)
        return bool(state and state.emit_suppressed)
    
    def reset(self, provider: str) -> None:
        """Reset the debounce state for a service (call on new client connection).
        
        This ensures the first status message is always sent after reconnection.
        Does NOT reset the actual health state.
        """
        state = self._services.get(provider)
        if state:
            state.reset_debounce()
            self._logger.debug(f"Reset debounce state for {provider}")
    
    def reset_all(self) -> None:
        """Reset all tracker debounce states (call on new client connection)."""
        for provider, state in self._services.items():
            state.reset_debounce()
            self._logger.debug(f"Reset debounce state for {provider}")


# Global health tracker instance
HEALTH_TRACKER = ServiceHealthTracker()
