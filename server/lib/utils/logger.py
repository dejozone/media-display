#!/usr/bin/env python3
"""
Logging Utilities
Provides structured logging for different components
"""
import sys
import logging
from pathlib import Path


class ColoredFormatter(logging.Formatter):
    """Custom formatter with colors for console output"""
    
    # ANSI color codes
    COLORS = {
        'DEBUG': '\033[36m',      # Cyan
        'INFO': '\033[32m',       # Green
        'WARNING': '\033[33m',    # Yellow
        'ERROR': '\033[31m',      # Red
        'CRITICAL': '\033[35m',   # Magenta
    }
    RESET = '\033[0m'
    
    def format(self, record):
        # Add color to level name
        levelname = record.levelname
        if levelname in self.COLORS:
            record.levelname = f"{self.COLORS[levelname]}{levelname}{self.RESET}"
        
        return super().format(record)


def setup_logger(name: str, level: str = 'INFO', log_format: str = 'detailed') -> logging.Logger:
    """
    Set up a logger with console and optional file output
    
    Args:
        name: Logger name (e.g., 'server', 'auth', 'database')
        level: Logging level ('DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL')
        log_format: 'simple' or 'detailed'
    
    Returns:
        Configured logger instance
    """
    logger = logging.getLogger(name)
    
    # Avoid duplicate handlers
    if logger.handlers:
        return logger
    
    logger.setLevel(getattr(logging, level.upper(), logging.INFO))
    
    # Console handler
    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setLevel(logging.DEBUG)
    
    # Format
    if log_format == 'simple':
        fmt = '%(levelname)s - %(message)s'
    else:
        fmt = '%(asctime)s | %(name)-12s | %(levelname)-8s | %(message)s'
    
    formatter = ColoredFormatter(
        fmt=fmt,
        datefmt='%Y-%m-%d %H:%M:%S'
    )
    
    console_handler.setFormatter(formatter)
    logger.addHandler(console_handler)
    
    return logger


def setup_file_logger(name: str, log_file: Path, level: str = 'INFO') -> logging.Logger:
    """
    Set up a logger with file output
    
    Args:
        name: Logger name
        log_file: Path to log file
        level: Logging level
    
    Returns:
        Configured logger instance
    """
    logger = logging.getLogger(name)
    
    # File handler
    log_file.parent.mkdir(parents=True, exist_ok=True)
    file_handler = logging.FileHandler(log_file)
    file_handler.setLevel(getattr(logging, level.upper(), logging.INFO))
    
    # Format for file (no colors)
    formatter = logging.Formatter(
        fmt='%(asctime)s | %(name)-12s | %(levelname)-8s | %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S'
    )
    
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)
    
    return logger


# =============================================================================
# PRE-CONFIGURED LOGGERS
# =============================================================================

# Load config to get log settings
try:
    # Add server directory to path for imports
    SERVER_DIR = Path(__file__).parent.parent.parent
    if str(SERVER_DIR) not in sys.path:
        sys.path.insert(0, str(SERVER_DIR))
    
    from config import Config
    LOG_LEVEL = Config.LOG_LEVEL
    LOG_FORMAT = Config.LOG_FORMAT
except ImportError:
    LOG_LEVEL = 'INFO'
    LOG_FORMAT = 'detailed'

# Server logger
server_logger = setup_logger('server', level=LOG_LEVEL, log_format=LOG_FORMAT)

# Auth logger
auth_logger = setup_logger('auth', level=LOG_LEVEL, log_format=LOG_FORMAT)

# Database logger
database_logger = setup_logger('database', level=LOG_LEVEL, log_format=LOG_FORMAT)

# WebSocket logger
websocket_logger = setup_logger('websocket', level=LOG_LEVEL, log_format=LOG_FORMAT)

# API logger (for external API calls - Spotify, Google)
api_logger = setup_logger('api', level=LOG_LEVEL, log_format=LOG_FORMAT)


if __name__ == '__main__':
    # Test loggers
    print("\n" + "=" * 60)
    print("TESTING LOGGERS")
    print("=" * 60 + "\n")
    
    server_logger.debug("This is a DEBUG message")
    server_logger.info("This is an INFO message")
    server_logger.warning("This is a WARNING message")
    server_logger.error("This is an ERROR message")
    
    print()
    auth_logger.info("✅ User authentication successful")
    database_logger.info("✅ Database connection established")
    websocket_logger.info("✅ WebSocket client connected")
    api_logger.info("✅ Spotify API call successful")
    
    print("\n" + "=" * 60)
    print("All loggers working correctly!")
    print("=" * 60 + "\n")
