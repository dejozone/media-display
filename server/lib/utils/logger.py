"""
Structured logging utility for the media display server.
Provides consistent logging format with levels and context.
"""

import logging
import sys
from typing import Optional

class StructuredLogger:
    """Structured logger with consistent formatting"""
    
    def __init__(self, name: str, level: int = logging.INFO):
        self.logger = logging.getLogger(name)
        self.logger.setLevel(level)
        
        # Remove existing handlers
        self.logger.handlers.clear()
        
        # Create console handler with formatting
        handler = logging.StreamHandler(sys.stdout)
        handler.setLevel(level)
        
        # Format: [TIME] [LEVEL] [SOURCE] Message
        formatter = logging.Formatter(
            '%(asctime)s [%(levelname)s] [%(name)s] %(message)s',
            datefmt='%Y-%m-%d %H:%M:%S'
        )
        handler.setFormatter(formatter)
        self.logger.addHandler(handler)
    
    def debug(self, message: str, **kwargs) -> None:
        """Log debug message"""
        extra_info = self._format_extras(kwargs)
        self.logger.debug(f"{message}{extra_info}")
    
    def info(self, message: str, **kwargs) -> None:
        """Log info message"""
        extra_info = self._format_extras(kwargs)
        self.logger.info(f"{message}{extra_info}")
    
    def warning(self, message: str, **kwargs) -> None:
        """Log warning message"""
        extra_info = self._format_extras(kwargs)
        self.logger.warning(f"{message}{extra_info}")
    
    def error(self, message: str, error: Optional[Exception] = None, **kwargs) -> None:
        """Log error message"""
        extra_info = self._format_extras(kwargs)
        if error:
            self.logger.error(f"{message}: {error}{extra_info}", exc_info=True)
        else:
            self.logger.error(f"{message}{extra_info}")
    
    def critical(self, message: str, **kwargs) -> None:
        """Log critical message"""
        extra_info = self._format_extras(kwargs)
        self.logger.critical(f"{message}{extra_info}")
    
    def _format_extras(self, extras: dict) -> str:
        """Format extra context as key=value pairs"""
        if not extras:
            return ""
        pairs = [f"{k}={v}" for k, v in extras.items()]
        return f" ({', '.join(pairs)})"


# Create singleton instances for different components
def get_logger(name: str, level: int = logging.INFO) -> StructuredLogger:
    """Get or create a logger for a component"""
    return StructuredLogger(name, level)


# Pre-configured loggers for common components
server_logger = get_logger("Server")
monitor_logger = get_logger("Monitor")
auth_logger = get_logger("Auth")
websocket_logger = get_logger("WebSocket")
