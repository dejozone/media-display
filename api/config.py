#!/usr/bin/env python3
"""
Configuration Management
Loads application settings from environment variables (.env) and JSON config files (conf/{ENV}.json)
"""
import os
import json
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

# Load JSON configuration based on ENV
ENV = os.getenv('ENV', 'dev')
CONF_DIR = SERVER_DIR / 'conf'
CONF_FILE = CONF_DIR / f'{ENV}.json'

if not CONF_FILE.exists():
    raise FileNotFoundError(f"Configuration file not found: {CONF_FILE}")

with open(CONF_FILE, 'r') as f:
    CONFIG = json.load(f)
    print(f"✅ Loaded configuration from: {CONF_FILE}")


class Config:
    """Application configuration - combines environment variables (.env) and JSON config (conf/{ENV}.json)"""
    
    # =============================================================================
    # ENVIRONMENT
    # =============================================================================
    ENV = ENV
    
    # =============================================================================
    # SERVER SETTINGS (from JSON config)
    # =============================================================================
    HOST = CONFIG['server']['host']
    PORT = CONFIG['server']['port']
    DEBUG = CONFIG['server']['debug']
    SECRET_KEY = os.getenv('SECRET_KEY', os.urandom(32).hex())  # from .env
    
    # =============================================================================
    # DATABASE SETTINGS (combined from JSON config and .env)
    # =============================================================================
    POSTGRES_HOST = CONFIG['database']['host']
    POSTGRES_PORT = CONFIG['database']['port']
    POSTGRES_DB = CONFIG['database']['name']
    POSTGRES_USER = CONFIG['database']['user']
    POSTGRES_PASSWORD = os.getenv('POSTGRES_PASSWORD', 'change_me')  # from .env (secure)
    DB_POOL_MIN_CONN = CONFIG['database']['poolMinConn']
    DB_POOL_MAX_CONN = CONFIG['database']['poolMaxConn']
    
    # Construct DATABASE_URL
    DATABASE_URL = os.getenv(
        'DATABASE_URL',
        f"postgresql://{POSTGRES_USER}:{POSTGRES_PASSWORD}@{POSTGRES_HOST}:{POSTGRES_PORT}/{POSTGRES_DB}"
    )
    
    # =============================================================================
    # CORS SETTINGS (from JSON config)
    # =============================================================================
    CORS_ORIGINS = CONFIG['cors']['origins']
    
    # =============================================================================
    # WEBSOCKET SETTINGS (from JSON config)
    # =============================================================================
    WEBSOCKET_PATH = CONFIG['websocket']['path']
    WEBSOCKET_ASYNC_MODE = CONFIG['websocket']['asyncMode']
    WEBSOCKET_CORS_ALLOWED_ORIGINS = CONFIG['websocket']['corsAllowedOrigins']
    
    # =============================================================================
    # GOOGLE OAUTH SETTINGS (combined from JSON config and .env)
    # =============================================================================
    GOOGLE_CLIENT_ID = os.getenv('GOOGLE_CLIENT_ID')  # from .env (secure)
    GOOGLE_CLIENT_SECRET = os.getenv('GOOGLE_CLIENT_SECRET')  # from .env (secure)
    GOOGLE_REDIRECT_URI = CONFIG['google']['redirectUri']
    GOOGLE_CONFIG = CONFIG.get('google', {})
    
    # =============================================================================
    # SPOTIFY OAUTH SETTINGS (combined from JSON config and .env)
    # =============================================================================
    SPOTIFY_CLIENT_ID = os.getenv('SPOTIFY_CLIENT_ID')  # from .env (secure)
    SPOTIFY_CLIENT_SECRET = os.getenv('SPOTIFY_CLIENT_SECRET')  # from .env (secure)
    _spotify_cfg = CONFIG.get('spotify', {})
    _spotify_api_cfg = _spotify_cfg.get('api', {}) if isinstance(_spotify_cfg, dict) else {}
    _spotify_main_cfg = _spotify_api_cfg.get('main', {}) if isinstance(_spotify_api_cfg, dict) else {}
    _spotify_account_cfg = _spotify_api_cfg.get('account', {}) if isinstance(_spotify_api_cfg, dict) else {}

    SPOTIFY_API_MAIN_BASE_URL = _spotify_main_cfg.get('baseUrl', 'https://api.spotify.com/v1').rstrip('/')
    _main_ssl_raw = _spotify_main_cfg.get('sslVerify', True)
    SPOTIFY_API_MAIN_SSL_VERIFY = _main_ssl_raw if isinstance(_main_ssl_raw, bool) else str(_main_ssl_raw).lower() == 'true'

    SPOTIFY_API_ACCOUNT_BASE_URL = _spotify_account_cfg.get('baseUrl', 'https://accounts.spotify.com').rstrip('/')
    _acct_ssl_raw = _spotify_account_cfg.get('sslVerify', True)
    SPOTIFY_API_ACCOUNT_SSL_VERIFY = _acct_ssl_raw if isinstance(_acct_ssl_raw, bool) else str(_acct_ssl_raw).lower() == 'true'

    SPOTIFY_REDIRECT_URI = os.getenv('SPOTIFY_REDIRECT_URI', _spotify_api_cfg.get('redirectUri', _spotify_cfg.get('redirectUri', '')))
    _spotify_scope_raw = os.getenv('SPOTIFY_SCOPE', _spotify_api_cfg.get('scope', _spotify_cfg.get('scope', '')))
    SPOTIFY_SCOPE = _spotify_scope_raw
    SPOTIFY_SCOPE_LIST = [s for s in _spotify_scope_raw.split(' ') if s] if isinstance(_spotify_scope_raw, str) else []

    SPOTIFY_AUTH_URL = f"{SPOTIFY_API_ACCOUNT_BASE_URL}/authorize"
    SPOTIFY_TOKEN_URL = f"{SPOTIFY_API_ACCOUNT_BASE_URL}/api/token"
    SPOTIFY_USER_INFO_URL = f"{SPOTIFY_API_MAIN_BASE_URL}/me"
    
    # =============================================================================
    # JWT SETTINGS (combined from JSON config and .env)
    # =============================================================================
    JWT_SECRET = os.getenv('JWT_SECRET', SECRET_KEY)  # from .env (secure)
    JWT_ALGORITHM = CONFIG['jwt']['algorithm']
    JWT_EXPIRATION_HOURS = CONFIG['jwt']['expirationHours']
    
    # =============================================================================
    # SESSION SETTINGS (from JSON config)
    # =============================================================================
    SESSION_TIMEOUT_MINUTES = CONFIG['session']['timeoutMinutes']
    
    # =============================================================================
    # RATE LIMITING (from JSON config)
    # =============================================================================
    RATE_LIMIT_SPOTIFY_API = CONFIG['rateLimit']['spotifyApiCallsPerMinute']
    
    # =============================================================================
    # LOGGING (from JSON config)
    # =============================================================================
    LOG_LEVEL = CONFIG['logging']['level']
    LOG_FORMAT = CONFIG['logging']['format']
    
    # =============================================================================
    # ASSETS (from JSON config)
    # =============================================================================
    ASSETS_BASE_URL = CONFIG['assets']['baseUrl'].rstrip('/')
    _image_upload_cfg = CONFIG['assets'].get('imageUpload', {})
    ASSETS_LOCAL_PATH = _image_upload_cfg.get('localPath', 'api/assets')
    ASSETS_ROOT = (ROOT_DIR / ASSETS_LOCAL_PATH).resolve()
    
    # Image Upload Settings
    MAX_AVATAR_UPLOAD_BYTES = _image_upload_cfg.get('maxFileSizeBytes', 8388608)  # Default 8MB
    ALLOWED_IMAGE_EXTENSIONS = set(_image_upload_cfg.get('allowedExtensions', ['.jpg', '.jpeg', '.png', '.bmp']))

    # =============================================================================
    # SSL/TLS (from JSON config)
    # =============================================================================
    SSL_VERIFY = CONFIG['ssl']['verify']

    # =============================================================================
    # FRONTEND (optional; defaults for local dev)
    # =============================================================================
    FRONTEND_BASE_URL = os.getenv('FRONTEND_BASE_URL', CONFIG.get('frontend', {}).get('baseUrl', 'http://localhost:5173')).rstrip('/')
    
    # =============================================================================
    # PATHS
    # =============================================================================
    SERVER_DIR = SERVER_DIR
    ROOT_DIR = ROOT_DIR
    CONF_DIR = CONF_DIR
    
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
        print(f"Environment:        {cls.ENV} ({'Development' if cls.DEBUG else 'Production'})")
        print(f"Config File:        {CONF_FILE}")
        print(f"Server:             {cls.HOST}:{cls.PORT}")
        print(f"Database:           {cls.POSTGRES_HOST}:{cls.POSTGRES_PORT}/{cls.POSTGRES_DB}")
        print(f"Database User:      {cls.POSTGRES_USER}")
        print(f"DB Pool:            {cls.DB_POOL_MIN_CONN}-{cls.DB_POOL_MAX_CONN} connections")
        print(f"CORS Origins:       {', '.join(cls.CORS_ORIGINS)}")
        print(f"WebSocket Path:     {cls.WEBSOCKET_PATH}")
        print(f"WebSocket Mode:     {cls.WEBSOCKET_ASYNC_MODE}")
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
