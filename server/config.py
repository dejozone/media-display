"""
Configuration management for the Now Playing Server.
Centralized configuration with validation and type safety.
"""
import os
from typing import Literal, Optional
from dotenv import load_dotenv

# Load environment variables
load_dotenv()


class Config:
    """Centralized configuration with validation"""
    
    # Flask Configuration
    SECRET_KEY: str = os.getenv('SECRET_KEY', 'your-secret-key-change-in-production')
    WEBAPP_SEND_FILE_MAX_AGE_DEFAULT: int = int(os.getenv('WEBAPP_SEND_FILE_MAX_AGE_DEFAULT', '86400'))  # 1 day in seconds
    
    # Server Configuration
    SERVER_HOST: str = os.getenv('SERVER_HOST', '0.0.0.0')
    WEBSOCKET_SERVER_PORT: int = int(os.getenv('WEBSOCKET_SERVER_PORT', '5001'))
    WEBSOCKET_PATH: str = os.getenv('WEBSOCKET_PATH', '/socket.io')
    
    # Spotify Configuration
    SPOTIFY_CLIENT_ID: Optional[str] = os.getenv('SPOTIFY_CLIENT_ID')
    SPOTIFY_CLIENT_SECRET: Optional[str] = os.getenv('SPOTIFY_CLIENT_SECRET')
    SPOTIFY_REDIRECT_URI: str = os.getenv('SPOTIFY_REDIRECT_URI', 'http://localhost:8888/callback')
    SPOTIFY_CACHE_PATH: str = '.spotify_cache'
    SPOTIFY_SCOPE: str = 'user-read-currently-playing user-read-playback-state'
    
    # SSL Configuration
    SSL_VERIFY_SPOTIFY: bool = os.getenv('SPOTIFY_SSL_CERT_VERIFICATION', 'true').lower() == 'true'
    
    # OAuth Callback Server
    LOCAL_CALLBACK_PORT: Optional[int] = None
    _local_port_str = os.getenv('LOCAL_CALLBACK_PORT', '').strip()
    if _local_port_str:
        try:
            LOCAL_CALLBACK_PORT = int(_local_port_str)
        except ValueError:
            print(f"⚠️  Invalid LOCAL_CALLBACK_PORT: '{_local_port_str}' (must be an integer)")
    
    # Service Configuration
    MEDIA_SERVICE_METHOD: Literal['sonos', 'spotify', 'all'] = 'all'
    _service_method = os.getenv('MEDIA_SERVICE_METHOD', 'all').lower().strip()
    if _service_method in ['sonos', 'spotify', 'all']:
        MEDIA_SERVICE_METHOD = _service_method  # type: ignore
    else:
        print(f"⚠️  Invalid MEDIA_SERVICE_METHOD: '{_service_method}' (defaulting to 'all')")
    
    # Service Recovery
    SERVICE_RECOVERY_WINDOW_TIME: int = int(os.getenv('SERVICE_RECOVERY_WINDOW_TIME', '86400'))  # seconds (default: 15 minutes)
    SERVICE_RECOVERY_RETRY_INTERVAL: int = int(os.getenv('SERVICE_RECOVERY_RETRY_INTERVAL', '15'))  # seconds (default: 15s)
    SERVICE_RECOVERY_INITIAL_DELAY: int = int(os.getenv('SERVICE_RECOVERY_INITIAL_DELAY', '15'))  # seconds to wait before starting recovery checks
    
    # Path Configuration
    _current_file = os.path.abspath(__file__)
    SERVER_DIR: str = os.path.dirname(_current_file)
    PROJECT_ROOT: str = os.path.dirname(SERVER_DIR)
    WEBAPP_DIR: str = os.path.join(PROJECT_ROOT, 'webapp')
    SCREENSAVER_DIR: str = os.path.join(WEBAPP_DIR, 'assets', 'images', 'screensavers')
    CERT_DIR: str = os.path.join(PROJECT_ROOT, 'certs')
    
    @classmethod
    def validate(cls) -> None:
        """Validate configuration and print warnings/errors"""
        errors = []
        warnings = []
        
        # Validate Spotify credentials if Spotify service is needed
        if cls.MEDIA_SERVICE_METHOD in ['spotify', 'all']:
            if not cls.SPOTIFY_CLIENT_ID:
                errors.append("SPOTIFY_CLIENT_ID is required when MEDIA_SERVICE_METHOD includes 'spotify'")
            if not cls.SPOTIFY_CLIENT_SECRET:
                errors.append("SPOTIFY_CLIENT_SECRET is required when MEDIA_SERVICE_METHOD includes 'spotify'")
        
        # Validate port ranges
        if not (1024 <= cls.WEBSOCKET_SERVER_PORT <= 65535):
            errors.append(f"WEBSOCKET_SERVER_PORT must be between 1024-65535, got {cls.WEBSOCKET_SERVER_PORT}")
        
        if cls.LOCAL_CALLBACK_PORT is not None and not (1024 <= cls.LOCAL_CALLBACK_PORT <= 65535):
            errors.append(f"LOCAL_CALLBACK_PORT must be between 1024-65535, got {cls.LOCAL_CALLBACK_PORT}")
        
        # Validate recovery timeout
        if cls.SERVICE_RECOVERY_WINDOW_TIME < 60:
            warnings.append(f"SERVICE_RECOVERY_WINDOW_TIME is very low ({cls.SERVICE_RECOVERY_WINDOW_TIME}s)")
        
        if cls.SERVICE_RECOVERY_RETRY_INTERVAL < 5:
            warnings.append(f"SERVICE_RECOVERY_RETRY_INTERVAL is very low ({cls.SERVICE_RECOVERY_RETRY_INTERVAL}s)")
        
        # Print warnings
        for warning in warnings:
            print(f"⚠️  Configuration Warning: {warning}")
        
        # Print errors and raise if any exist
        if errors:
            print("\n❌ Configuration Errors:")
            for error in errors:
                print(f"   • {error}")
            raise ValueError(f"Invalid configuration: {len(errors)} error(s) found")
    
    @classmethod
    def print_config(cls) -> None:
        """Print current configuration (for debugging)"""
        print("\n📋 Configuration:")
        print(f"   MEDIA_SERVICE_METHOD: {cls.MEDIA_SERVICE_METHOD}")
        print(f"   SERVER_HOST: {cls.SERVER_HOST}")
        print(f"   WEBSOCKET_SERVER_PORT: {cls.WEBSOCKET_SERVER_PORT}")
        print(f"   WEBSOCKET_PATH: {cls.WEBSOCKET_PATH}")
        print(f"   SSL_VERIFY_SPOTIFY: {cls.SSL_VERIFY_SPOTIFY}")
        
        # Format recovery window time smartly
        window_time = cls.SERVICE_RECOVERY_WINDOW_TIME
        if window_time <= 60:
            window_display = f"{window_time}s"
        else:
            window_display = f"{window_time / 60:.1f} minutes"
        print(f"   SERVICE_RECOVERY_WINDOW_TIME: {window_display}")
        print(f"   SERVICE_RECOVERY_RETRY_INTERVAL: {cls.SERVICE_RECOVERY_RETRY_INTERVAL}s")
        
        if cls.LOCAL_CALLBACK_PORT:
            print(f"   LOCAL_CALLBACK_PORT: {cls.LOCAL_CALLBACK_PORT}")
        print()
    
    @classmethod
    def get_desired_services(cls) -> set[str]:
        """Get set of services that should be active based on configuration"""
        if cls.MEDIA_SERVICE_METHOD == 'spotify':
            return {'spotify'}
        elif cls.MEDIA_SERVICE_METHOD == 'sonos':
            return {'sonos'}
        else:  # 'all'
            return {'spotify', 'sonos'}
