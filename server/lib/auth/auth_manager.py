#!/usr/bin/env python3
"""
Auth Manager
Handles JWT creation, validation, refresh, and integrates with Google/Spotify OAuth clients
"""
import os
import sys
from pathlib import Path
from typing import Dict, Any, Optional
import time
import jwt

# Add server directory to path for imports
SERVER_DIR = Path(__file__).parent.parent.parent
if str(SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(SERVER_DIR))

from config import Config
from lib.auth.google_oauth import GoogleOAuthClient
from lib.auth.spotify_oauth import SpotifyOAuthClient
from lib.utils.logger import auth_logger as logger

class AuthManager:
    """Authentication manager for JWT and OAuth integration"""
    def __init__(self):
        self.jwt_secret = Config.JWT_SECRET
        self.jwt_algorithm = Config.JWT_ALGORITHM
        self.jwt_expiration = Config.JWT_EXPIRATION_HOURS * 3600  # seconds
        self.google_client = GoogleOAuthClient()
        self.spotify_client = SpotifyOAuthClient()
        # In-memory spotify tokens keyed by user_id (demo; replace with persistent storage in production)
        self.spotify_tokens: Dict[str, Dict[str, Any]] = {}

    def create_jwt(self, user_info: Dict[str, Any], provider: str) -> str:
        payload = {
            'sub': user_info['id'],
            'provider': provider,
            'email': user_info.get('email'),
            'name': user_info.get('name'),
            'iat': int(time.time()),
            'exp': int(time.time()) + self.jwt_expiration
        }
        token = jwt.encode(payload, self.jwt_secret, algorithm=self.jwt_algorithm)
        logger.info(f"Created JWT for user {user_info.get('email', user_info['id'])} via {provider}")
        return token

    def validate_jwt(self, token: str) -> Optional[Dict[str, Any]]:
        try:
            payload = jwt.decode(token, self.jwt_secret, algorithms=[self.jwt_algorithm])
            logger.info(f"Validated JWT for user {payload.get('email', payload['sub'])}")
            return payload
        except jwt.ExpiredSignatureError:
            logger.error("JWT token expired")
            return None
        except jwt.InvalidTokenError:
            logger.error("Invalid JWT token")
            return None

    def login_with_google(self, code: str) -> Optional[str]:
        try:
            result = self.google_client.complete_oauth_flow(code)
            user_info = result['user_info']
            token = self.create_jwt(user_info, provider='google')
            return token
        except Exception as e:
            logger.error(f"Google login failed: {str(e)}")
            return None

    def login_with_spotify(self, code: str) -> Optional[str]:
        try:
            result = self.spotify_client.complete_oauth_flow(code)
            user_info = result['user_info']
            tokens = result['tokens']
            # Track expiry
            tokens['expires_at'] = int(time.time()) + tokens.get('expires_in', 3600)
            self.spotify_tokens[user_info['id']] = tokens
            token = self.create_jwt(user_info, provider='spotify')
            return token
        except Exception as e:
            logger.error(f"Spotify login failed: {str(e)}")
            return None

    # ------------------------------------------------------------------
    # Spotify token management (in-memory demo)
    # ------------------------------------------------------------------
    def _ensure_valid_spotify_access_token(self, user_id: str) -> Optional[str]:
        tokens = self.spotify_tokens.get(user_id)
        if not tokens:
            return None
        now = int(time.time())
        if tokens.get('expires_at', 0) > now + 30:
            return tokens.get('access_token')
        refresh_token = tokens.get('refresh_token')
        if not refresh_token:
            return None
        refreshed = self.spotify_client.refresh_access_token(refresh_token)
        refreshed['expires_at'] = int(time.time()) + refreshed.get('expires_in', 3600)
        # If Spotify does not return refresh_token on refresh, keep old one
        if 'refresh_token' not in refreshed and refresh_token:
            refreshed['refresh_token'] = refresh_token
        self.spotify_tokens[user_id] = refreshed
        return refreshed.get('access_token')

    def get_spotify_currently_playing(self, user_id: str) -> Optional[Dict[str, Any]]:
        access_token = self._ensure_valid_spotify_access_token(user_id)
        if not access_token:
            return None
        return self.spotify_client.get_currently_playing(access_token)

# =============================================================================
# STANDALONE TESTING
# =============================================================================
if __name__ == '__main__':
    print("\n" + "=" * 70)
    print("TESTING AUTH MANAGER")
    print("=" * 70 + "\n")
    manager = AuthManager()
    print("1️⃣  AuthManager initialized.")
    print(f"   JWT secret: {manager.jwt_secret[:8]}... (hidden)")
    print(f"   JWT algorithm: {manager.jwt_algorithm}")
    print(f"   JWT expiration: {manager.jwt_expiration // 3600} hours")
    print("   ✅ Ready for OAuth login and JWT operations\n")
    print("To test login, use manager.login_with_google(code) or manager.login_with_spotify(code)")
    print("To test JWT validation, use manager.validate_jwt(token)")
    print("\n" + "=" * 70 + "\n")
