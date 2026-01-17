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
import uuid
import jwt
import psycopg2
from psycopg2.extras import RealDictCursor

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
        # DB connection for token persistence
        self.db_conn = psycopg2.connect(
            dbname=Config.POSTGRES_DB,
            user=Config.POSTGRES_USER,
            password=Config.POSTGRES_PASSWORD,
            host=Config.POSTGRES_HOST,
            port=Config.POSTGRES_PORT,
        )
        self.db_conn.autocommit = True

    def _fetch_one(self, query: str, params: tuple) -> Optional[Dict[str, Any]]:
        with self.db_conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(query, params)
            return cur.fetchone()

    def _execute(self, query: str, params: tuple) -> None:
        with self.db_conn.cursor() as cur:
            cur.execute(query, params)

    def create_jwt(self, user: Dict[str, Any], provider: str) -> str:
        payload = {
            'sub': str(user['id']),
            'provider': provider,
            'email': user.get('email'),
            'name': user.get('display_name') or user.get('username') or user.get('email'),
            'iat': int(time.time()),
            'exp': int(time.time()) + self.jwt_expiration
        }
        token = jwt.encode(payload, self.jwt_secret, algorithm=self.jwt_algorithm)
        logger.info(f"Created JWT for user {user.get('email', user['id'])} via {provider}")
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

    def _get_user_by_google_id(self, google_id: str) -> Optional[Dict[str, Any]]:
        return self._fetch_one("SELECT * FROM users WHERE google_id = %s", (google_id,))

    def _get_user_by_email(self, email: str) -> Optional[Dict[str, Any]]:
        return self._fetch_one("SELECT * FROM users WHERE email = %s", (email,))

    def _create_google_user(self, user_info: Dict[str, Any]) -> Dict[str, Any]:
        user_id = uuid.uuid4()
        email = user_info.get('email')
        username = (email.split('@')[0] if email else f"google_{user_info.get('id')}")[:50]
        display_name = user_info.get('name') or username
        self._execute(
            """
            INSERT INTO users (id, email, username, display_name, google_id)
            VALUES (%s, %s, %s, %s, %s)
            """,
            (str(user_id), email, username, display_name, user_info.get('id'))
        )
        return self._fetch_one("SELECT * FROM users WHERE id = %s", (str(user_id),))

    def login_with_google(self, code: str) -> Optional[str]:
        try:
            result = self.google_client.complete_oauth_flow(code)
            user_info = result['user_info']
            user = self._get_user_by_google_id(user_info.get('id')) or self._get_user_by_email(user_info.get('email'))
            if not user:
                user = self._create_google_user(user_info)
            token = self.create_jwt(user, provider='google')
            return token
        except Exception as e:
            logger.error(f"Google login failed: {str(e)}")
            return None

    def _get_user_by_spotify_id(self, spotify_id: str) -> Optional[Dict[str, Any]]:
        return self._fetch_one(
            "SELECT u.* FROM users u JOIN spotify_tokens s ON u.id = s.user_id WHERE s.spotify_id = %s",
            (spotify_id,)
        )

    def _create_spotify_user(self, profile: Dict[str, Any]) -> Dict[str, Any]:
        user_id = uuid.uuid4()
        spotify_id = profile.get('id')
        email = profile.get('email') or f"{spotify_id}@spotify.local"
        username = (profile.get('display_name') or spotify_id).replace(' ', '_')[:50]
        display_name = profile.get('display_name') or spotify_id
        self._execute(
            """
            INSERT INTO users (id, email, username, display_name)
            VALUES (%s, %s, %s, %s)
            """,
            (str(user_id), email, username, display_name)
        )
        return self._fetch_one("SELECT * FROM users WHERE id = %s", (str(user_id),))

    def _get_db_spotify_tokens(self, user_id: str) -> Optional[Dict[str, Any]]:
        return self._fetch_one(
            "SELECT spotify_id, access_token, refresh_token, token_expires_at FROM spotify_tokens WHERE user_id = %s",
            (user_id,)
        )

    # ------------------------------------------------------------------
    # Spotify token management (DB-backed, keyed by user_id UUID)
    # ------------------------------------------------------------------
    def _save_spotify_tokens(self, user_id: str, spotify_id: str, tokens: Dict[str, Any]) -> None:
        self._execute(
            """
            INSERT INTO spotify_tokens (user_id, spotify_id, access_token, refresh_token, token_expires_at)
            VALUES (%s, %s, %s, %s, %s)
            ON CONFLICT (user_id) DO UPDATE SET
                spotify_id = EXCLUDED.spotify_id,
                access_token = EXCLUDED.access_token,
                refresh_token = EXCLUDED.refresh_token,
                token_expires_at = EXCLUDED.token_expires_at,
                last_refreshed_at = CURRENT_TIMESTAMP
            """,
            (
                str(user_id),
                spotify_id,
                tokens.get('access_token'),
                tokens.get('refresh_token'),
                tokens.get('expires_at'),
            ),
        )

    def _ensure_valid_spotify_access_token(self, user_id: str) -> Optional[str]:
        tokens = self._get_db_spotify_tokens(user_id)
        if not tokens:
            logger.warning(f"No Spotify tokens cached for user {user_id}")
            return None
        now = int(time.time())
        if tokens.get('token_expires_at', 0) > now + 30:
            logger.debug(f"Using cached Spotify access token for user {user_id}")
            return tokens.get('access_token')
        refresh_token = tokens.get('refresh_token')
        if not refresh_token:
            logger.warning(f"No refresh token available for user {user_id}")
            return None
        logger.info(f"Refreshing Spotify token for user {user_id}")
        refreshed = self.spotify_client.refresh_access_token(refresh_token)
        refreshed['expires_at'] = int(time.time()) + refreshed.get('expires_in', 3600)
        if 'refresh_token' not in refreshed and refresh_token:
            refreshed['refresh_token'] = refresh_token
        self._save_spotify_tokens(user_id, tokens.get('spotify_id'), refreshed)
        logger.info(f"Refreshed Spotify token for user {user_id}; expires_at={refreshed['expires_at']}")
        return refreshed.get('access_token')

    def get_spotify_currently_playing(self, user_id: str) -> Optional[Dict[str, Any]]:
        access_token = self._ensure_valid_spotify_access_token(user_id)
        if not access_token:
            logger.warning(f"Cannot fetch now playing; no valid access token for user {user_id}")
            return None
        try:
            now_playing = self.spotify_client.get_currently_playing(access_token)
            logger.info(f"Fetched now playing for user {user_id}; empty={not bool(now_playing)}")
            return now_playing
        except Exception as e:
            logger.error(f"Error fetching now playing for user {user_id}: {e}")
            return None

    def login_with_spotify(self, code: str) -> Optional[str]:
        try:
            result = self.spotify_client.complete_oauth_flow(code)
            profile = result['user_info']
            tokens = result['tokens']
            spotify_id = profile.get('id')
            user = self._get_user_by_spotify_id(spotify_id)
            if not user:
                user = self._create_spotify_user(profile)
            tokens['expires_at'] = int(time.time()) + tokens.get('expires_in', 3600)
            self._save_spotify_tokens(user['id'], spotify_id, tokens)
            token = self.create_jwt(user, provider='spotify')
            return token
        except Exception as e:
            logger.error(f"Spotify login failed: {str(e)}")
            return None

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
