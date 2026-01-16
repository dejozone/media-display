#!/usr/bin/env python3
"""
Configuration Management
Loads and manages all application settings from environment variables
"""
import os
from pathlib import Path
from dotenv import load_dotenv

# Load environment variables from server .env file (with fallback to root)
SERVER_DIR = Path(__file__).parent
ROOT_DIR = SERVER_DIR.parent
SERVER_ENV_FILE = SERVER_DIR / '.env'
ROOT_ENV_FILE = ROOT_DIR / '.env'

# Try server .env first, then fallback to root .env
if SERVER_ENV_FILE.exists():
    load_dotenv(SERVER_ENV_FILE)
    print(f"✅ Loaded environment from: {SERVER_ENV_FILE}")
elif ROOT_ENV_FILE.exists():
    load_dotenv(ROOT_ENV_FILE)
    print(f"✅ Loaded environment from: {ROOT_ENV_FILE} (fallback)")
else:
    print(f"⚠️  No .env file found at: {SERVER_ENV_FILE} or {ROOT_ENV_FILE}")


class Config:
    """Application configuration"""
    
    # =============================================================================
    # SERVER SETTINGS
    # =============================================================================
    HOST = os.getenv('HOST', '0.0.0.0')
    PORT = int(os.getenv('PORT', 5001))
    DEBUG = os.getenv('DEBUG', 'False').lower() == 'true'
    SECRET_KEY = os.getenv('SECRET_KEY', os.urandom(32).hex())
    
    # =============================================================================
    # DATABASE SETTINGS
    # =============================================================================
    POSTGRES_USER = os.getenv('POSTGRES_USER', 'nowplaying')
    POSTGRES_PASSWORD = os.getenv('POSTGRES_PASSWORD', 'nowplaying_dev_password')
    POSTGRES_DB = os.getenv('POSTGRES_DB', 'nowplaying')
    POSTGRES_HOST = os.getenv('POSTGRES_HOST', 'localhost')
    POSTGRES_PORT = int(os.getenv('POSTGRES_PORT', 5432))
    
    # Construct DATABASE_URL
    DATABASE_URL = os.getenv(
        'DATABASE_URL',
        f"postgresql://{POSTGRES_USER}:{POSTGRES_PASSWORD}@{POSTGRES_HOST}:{POSTGRES_PORT}/{POSTGRES_DB}"
    )
    
    # =============================================================================
    # CORS SETTINGS
    # =============================================================================
    CORS_ORIGINS = os.getenv('CORS_ORIGINS', 'http://localhost:3000,http://localhost:5001').split(',')
    
    # =============================================================================
    # WEBSOCKET SETTINGS
    # =============================================================================
    WEBSOCKET_PATH = os.getenv('WEBSOCKET_PATH', '/ws/socket.io')
    WEBSOCKET_CORS_ALLOWED_ORIGINS = CORS_ORIGINS
    
    # =============================================================================
    # GOOGLE OAUTH SETTINGS
    # =============================================================================
    GOOGLE_CLIENT_ID = os.getenv('GOOGLE_CLIENT_ID')
    GOOGLE_CLIENT_SECRET = os.getenv('GOOGLE_CLIENT_SECRET')
    GOOGLE_REDIRECT_URI = os.getenv(
        'GOOGLE_REDIRECT_URI',
        f'http://{HOST}:{PORT}/auth/google/callback'
    )
    
    # =============================================================================
    # SPOTIFY OAUTH SETTINGS
    # =============================================================================
    SPOTIFY_CLIENT_ID = os.getenv('SPOTIFY_CLIENT_ID')
    SPOTIFY_CLIENT_SECRET = os.getenv('SPOTIFY_CLIENT_SECRET')
    SPOTIFY_REDIRECT_URI = os.getenv(
        'SPOTIFY_REDIRECT_URI',
        f'http://{HOST}:{PORT}/auth/spotify/callback'
    )
    SPOTIFY_SCOPE = os.getenv(
        'SPOTIFY_SCOPE',
        'user-read-currently-playing user-read-playback-state user-read-email user-read-private'
    )
    
    # =============================================================================
    # JWT SETTINGS
    # =============================================================================
    JWT_SECRET = os.getenv('JWT_SECRET', SECRET_KEY)
    JWT_ALGORITHM = 'HS256'
    JWT_EXPIRATION_HOURS = int(os.getenv('JWT_EXPIRATION_HOURS', 24))
    
    # =============================================================================
    # SESSION SETTINGS
    # =============================================================================
    SESSION_TIMEOUT_MINUTES = int(os.getenv('SESSION_TIMEOUT_MINUTES', 30))
    
    # =============================================================================
    # RATE LIMITING
    # =============================================================================
    RATE_LIMIT_SPOTIFY_API = int(os.getenv('RATE_LIMIT_SPOTIFY_API', 100))  # calls per minute per user
    
    # =============================================================================
    # LOGGING
    # =============================================================================
    LOG_LEVEL = os.getenv('LOG_LEVEL', 'INFO')
    LOG_FORMAT = os.getenv('LOG_FORMAT', 'detailed')  # 'simple' or 'detailed'
    
    # =============================================================================
    # SSL/TLS
    # =============================================================================
    SSL_VERIFY = os.getenv('SSL_VERIFY', 'True').lower() == 'true'
    
    # =============================================================================
    # PATHS
    # =============================================================================
    SERVER_DIR = SERVER_DIR
    ROOT_DIR = ROOT_DIR
    
    @classmethod
    def validate(cls):
        """Validate required configuration"""
        errors = []
        
        # Check required OAuth credentials
        if not cls.GOOGLE_CLIENT_ID:
            errors.append("GOOGLE_CLIENT_ID is not set")
        if not cls.GOOGLE_CLIENT_SECRET:
            errors.append("GOOGLE_CLIENT_SECRET is not set")
        if not cls.SPOTIFY_CLIENT_ID:
            errors.append("SPOTIFY_CLIENT_ID is not set")
        if not cls.SPOTIFY_CLIENT_SECRET:
            errors.append("SPOTIFY_CLIENT_SECRET is not set")
        
        if errors:
            print("\n⚠️  Configuration Warnings:")
            for error in errors:
                print(f"   - {error}")
            print("   Note: OAuth features will not work until these are configured\n")
        
        return len(errors) == 0
    
    @classmethod
    def print_config(cls):
        """Print current configuration (masked sensitive values)"""
        print("\n" + "=" * 60)
        print("APPLICATION CONFIGURATION")
        print("=" * 60)
        print(f"Environment:        {'Development' if cls.DEBUG else 'Production'}")
        print(f"Server:             {cls.HOST}:{cls.PORT}")
        print(f"Database:           {cls.POSTGRES_HOST}:{cls.POSTGRES_PORT}/{cls.POSTGRES_DB}")
        print(f"Database User:      {cls.POSTGRES_USER}")
        print(f"CORS Origins:       {', '.join(cls.CORS_ORIGINS)}")
        print(f"WebSocket Path:     {cls.WEBSOCKET_PATH}")
        print(f"JWT Expiration:     {cls.JWT_EXPIRATION_HOURS} hours")
        print(f"Session Timeout:    {cls.SESSION_TIMEOUT_MINUTES} minutes")
        print(f"Log Level:          {cls.LOG_LEVEL}")
        print(f"Google OAuth:       {'✅ Configured' if cls.GOOGLE_CLIENT_ID else '❌ Not configured'}")
        print(f"Spotify OAuth:      {'✅ Configured' if cls.SPOTIFY_CLIENT_ID else '❌ Not configured'}")
        print("=" * 60 + "\n")


# Validate configuration on import
Config.validate()


if __name__ == '__main__':
    # Test configuration loading
    Config.print_config()
