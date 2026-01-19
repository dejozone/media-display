#!/usr/bin/env python3
"""
Auth Manager
Handles JWT creation, validation, refresh, and integrates with Google/Spotify OAuth clients
"""
import os
import sys
from pathlib import Path
from typing import Dict, Any, Optional, Tuple, List
import time
import uuid
import jwt
import psycopg2
from psycopg2 import InterfaceError, OperationalError
from psycopg2.extras import RealDictCursor

# Add server directory to path for imports
SERVER_DIR = Path(__file__).parent.parent.parent
if str(SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(SERVER_DIR))

from config import Config
from lib.auth.google_oauth import GoogleOAuthClient
from lib.auth.spotify_oauth import SpotifyOAuthClient
from lib.utils.logger import auth_logger as logger

SqlParams = Optional[Tuple[Any, ...]]

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

    def _ensure_conn(self) -> None:
        if not self.db_conn or self.db_conn.closed:
            logger.warning("DB connection closed; reconnecting")
            self.db_conn = psycopg2.connect(
                dbname=Config.POSTGRES_DB,
                user=Config.POSTGRES_USER,
                password=Config.POSTGRES_PASSWORD,
                host=Config.POSTGRES_HOST,
                port=Config.POSTGRES_PORT,
            )
            self.db_conn.autocommit = True

    def _fetch_one(self, query: str, params: SqlParams = None) -> Optional[Dict[str, Any]]:
        self._ensure_conn()
        try:
            with self.db_conn.cursor(cursor_factory=RealDictCursor) as cur:
                cur.execute(query, params or ())
                return cur.fetchone()
        except (InterfaceError, OperationalError):
            self._ensure_conn()
            with self.db_conn.cursor(cursor_factory=RealDictCursor) as cur:
                cur.execute(query, params or ())
                return cur.fetchone()

    def _fetch_all(self, query: str, params: SqlParams = None) -> List[Dict[str, Any]]:
        """Return rows as plain dicts to satisfy type checkers."""
        self._ensure_conn()
        try:
            with self.db_conn.cursor(cursor_factory=RealDictCursor) as cur:
                cur.execute(query, params or ())
                return [dict(row) for row in (cur.fetchall() or [])]
        except (InterfaceError, OperationalError):
            self._ensure_conn()
            with self.db_conn.cursor(cursor_factory=RealDictCursor) as cur:
                cur.execute(query, params or ())
                return [dict(row) for row in (cur.fetchall() or [])]

    def _execute(self, query: str, params: SqlParams = None) -> None:
        self._ensure_conn()
        try:
            with self.db_conn.cursor() as cur:
                cur.execute(query, params or ())
        except (InterfaceError, OperationalError):
            self._ensure_conn()
            with self.db_conn.cursor() as cur:
                cur.execute(query, params or ())

    # ---------------------------------------------------------------------
    # Dashboard settings helpers
    # ---------------------------------------------------------------------
    def _ensure_dashboard_settings(self, user_id: str) -> None:
        """Create dashboard_settings row if absent."""
        self._execute(
            """
            INSERT INTO dashboard_settings (user_id)
            VALUES (%s)
            ON CONFLICT (user_id) DO NOTHING
            """,
            (user_id,),
        )

    def get_dashboard_settings(self, user_id: str) -> Optional[Dict[str, Any]]:
        self._ensure_dashboard_settings(user_id)
        return self._fetch_one(
            "SELECT * FROM dashboard_settings WHERE user_id = %s",
            (user_id,),
        )

    def update_dashboard_settings(
        self,
        user_id: str,
        spotify_enabled: Optional[bool] = None,
        sonos_enabled: Optional[bool] = None,
    ) -> Optional[Dict[str, Any]]:
        self._ensure_dashboard_settings(user_id)
        set_clauses = []
        params: Tuple[Any, ...] = tuple()

        if spotify_enabled is not None:
            set_clauses.append("spotify_enabled = %s")
            params += (spotify_enabled,)
        if sonos_enabled is not None:
            set_clauses.append("sonos_enabled = %s")
            params += (sonos_enabled,)

        if not set_clauses:
            return self.get_dashboard_settings(user_id)

        set_clause = ", ".join(set_clauses) + ", updated_at = CURRENT_TIMESTAMP"
        params += (user_id,)

        return self._fetch_one(
            f"UPDATE dashboard_settings SET {set_clause} WHERE user_id = %s RETURNING *",
            params,
        )

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

    def create_state_token(self, user_id: Optional[str] = None, ttl_seconds: int = 600) -> str:
        payload: Dict[str, Any] = {
            'nonce': str(uuid.uuid4()),
            'iat': int(time.time()),
            'exp': int(time.time()) + ttl_seconds,
        }
        if user_id:
            payload['sub'] = str(user_id)
        return jwt.encode(payload, self.jwt_secret, algorithm=self.jwt_algorithm)

    def verify_state_token(self, state_token: str) -> Optional[str]:
        try:
            payload = jwt.decode(state_token, self.jwt_secret, algorithms=[self.jwt_algorithm])
            return payload.get('sub')
        except jwt.InvalidTokenError:
            logger.warning("Invalid or expired state token")
            return None

    def validate_jwt(self, token: str) -> Optional[Dict[str, Any]]:
        try:
            payload = jwt.decode(token, self.jwt_secret, algorithms=[self.jwt_algorithm])
            logger.debug(f"Validated JWT for user {payload.get('email', payload['sub'])}")
            return payload
        except jwt.ExpiredSignatureError:
            logger.error("JWT token expired")
            return None
        except jwt.InvalidTokenError:
            logger.error("Invalid JWT token")
            return None

    def _get_user_by_id(self, user_id: str) -> Optional[Dict[str, Any]]:
        return self._fetch_one("SELECT * FROM users WHERE id = %s", (str(user_id),))

    def _get_user_by_email(self, email: str) -> Optional[Dict[str, Any]]:
        return self._fetch_one("SELECT * FROM users WHERE email = %s", (email,))

    def _create_google_user(self, user_info: Dict[str, Any]) -> Dict[str, Any]:
        user_id = uuid.uuid4()
        email = user_info.get('email')
        username = (email.split('@')[0] if email else f"google_{user_info.get('id')}")[:50]
        display_name = user_info.get('name') or username
        self._execute(
            """
            INSERT INTO users (id, email, username, display_name)
            VALUES (%s, %s, %s, %s)
            """,
            (str(user_id), email, username, display_name)
        )
        created = self._fetch_one("SELECT * FROM users WHERE id = %s", (str(user_id),))
        if not created:
            raise RuntimeError("Failed to fetch newly created Google user")
        return created

    def login_with_google(self, code: str) -> Optional[str]:
        try:
            result = self.google_client.complete_oauth_flow(code)
            if not result or 'user_info' not in result:
                logger.error("Google login failed: empty result or missing user_info")
                return None
            user_info = result['user_info']
            avatar_url = user_info.get('picture') or user_info.get('photo')
            google_id = user_info.get('id')
            user: Optional[Dict[str, Any]] = None

            if google_id:
                identity = self._get_identity('google', google_id)
                if identity:
                    user = self._get_user_by_id(identity['user_id'])

            if not user:
                user = self._get_user_by_email(user_info.get('email'))

            if not user:
                user = self._create_google_user(user_info)

            if google_id:
                self._link_identity(
                    user['id'], 'google', google_id, avatar_url=avatar_url, select_if_none=True
                )
                self._select_identity(user['id'], 'google', google_id)
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

    def _get_identity(self, provider: str, provider_id: str) -> Optional[Dict[str, Any]]:
        return self._fetch_one(
            "SELECT * FROM identities WHERE provider = %s AND provider_id = %s",
            (provider, provider_id),
        )

    def get_user(self, user_id: str) -> Optional[Dict[str, Any]]:
        return self._get_user_by_id(user_id)

    def get_identities(self, user_id: str) -> List[Dict[str, Any]]:
        return self._fetch_all(
            "SELECT * FROM identities WHERE user_id = %s",
            (str(user_id),),
        )

    def username_exists(self, username: str, exclude_user_id: Optional[str] = None) -> bool:
        if exclude_user_id:
            row = self._fetch_one(
                "SELECT 1 FROM users WHERE username = %s AND id <> %s",
                (username, str(exclude_user_id)),
            )
        else:
            row = self._fetch_one(
                "SELECT 1 FROM users WHERE username = %s",
                (username,),
            )
        return row is not None

    def update_user(
        self,
        user_id: str,
        *,
        email: Optional[str] = None,
        username: Optional[str] = None,
        display_name: Optional[str] = None,
    ) -> Optional[Dict[str, Any]]:
        set_clauses = []
        params: Tuple[Any, ...] = tuple()
        if email is not None:
            set_clauses.append("email = %s")
            params += (email,)
        if username is not None:
            set_clauses.append("username = %s")
            params += (username,)
        if display_name is not None:
            set_clauses.append("display_name = %s")
            params += (display_name,)
        if not set_clauses:
            return self._get_user_by_id(user_id)

        params += (str(user_id),)
        set_clause = ", ".join(set_clauses)
        return self._fetch_one(
            f"UPDATE users SET {set_clause}, updated_at = CURRENT_TIMESTAMP WHERE id = %s RETURNING *",
            params,
        )

    def update_identity_avatar(self, user_id: str, avatar_url: Optional[str]) -> None:
        # Update only the currently selected identity; never overwrite other providers unintentionally
        identity = self._fetch_one(
            "SELECT provider, provider_id FROM identities WHERE user_id = %s AND is_selected = TRUE ORDER BY created_at DESC LIMIT 1",
            (str(user_id),),
        )
        if not identity:
            return

        self._execute(
            "UPDATE identities SET avatar_url = %s WHERE user_id = %s AND provider = %s AND provider_id = %s",
            (avatar_url, str(user_id), identity['provider'], identity['provider_id']),
        )

    def select_identity_by_provider(self, user_id: str, provider: str) -> None:
        # Pick the newest identity for the provider and mark it selected, deselecting others
        identity = self._fetch_one(
            "SELECT provider, provider_id FROM identities WHERE user_id = %s AND provider = %s ORDER BY created_at DESC LIMIT 1",
            (str(user_id), provider),
        )
        if not identity:
            return
        self._select_identity(str(user_id), identity['provider'], identity['provider_id'])

    def _link_identity(self, user_id: str, provider: str, provider_id: str, avatar_url: Optional[str] = None, select_if_none: bool = False) -> None:
        is_selected = False
        if select_if_none:
            existing_selected = self._fetch_one(
                "SELECT 1 FROM identities WHERE user_id = %s AND is_selected = TRUE LIMIT 1",
                (str(user_id),),
            )
            is_selected = existing_selected is None

        self._execute(
            """
            INSERT INTO identities (user_id, provider, provider_id, avatar_url, is_selected)
            VALUES (%s, %s, %s, %s, %s)
            ON CONFLICT (provider, provider_id) DO UPDATE SET
                user_id = EXCLUDED.user_id,
                avatar_url = COALESCE(EXCLUDED.avatar_url, identities.avatar_url),
                is_selected = identities.is_selected OR EXCLUDED.is_selected
            """,
            (str(user_id), provider, provider_id, avatar_url, is_selected),
        )

    def _reassign_spotify_identity(self, old_user_id: str, new_user_id: str, spotify_id: str, avatar_url: Optional[str]) -> None:
        # Move identity and tokens to the new user, then remove the old user record
        self._execute(
            """
            UPDATE identities
            SET user_id = %s, avatar_url = COALESCE(%s, avatar_url), is_selected = TRUE
            WHERE provider = 'spotify' AND provider_id = %s
            """,
            (str(new_user_id), avatar_url, spotify_id),
        )
        self._execute(
            """
            UPDATE spotify_tokens
            SET user_id = %s
            WHERE user_id = %s
            """,
            (str(new_user_id), str(old_user_id)),
        )
        # Deselect other identities for the new user and select this spotify identity
        self._select_identity(str(new_user_id), 'spotify', spotify_id)
        # Remove old user row now that associations are moved
        self._execute("DELETE FROM users WHERE id = %s", (str(old_user_id),))

    def _select_identity(self, user_id: str, provider: str, provider_id: str) -> None:
        # Select the given identity for the user and deselect others
        self._execute(
            """
            UPDATE identities
            SET is_selected = (provider = %s AND provider_id = %s)
            WHERE user_id = %s
            """,
            (provider, provider_id, str(user_id)),
        )

    def _get_selected_avatar_url(self, user_id: str) -> Optional[str]:
        row = self._fetch_one(
            """
            SELECT avatar_url
            FROM identities
            WHERE user_id = %s AND is_selected = TRUE
            ORDER BY created_at ASC
            LIMIT 1
            """,
            (str(user_id),),
        )
        if row:
            return row.get('avatar_url')
        return None

    def get_selected_avatar_url(self, user_id: str) -> Optional[str]:
        return self._get_selected_avatar_url(user_id)

    def _create_spotify_user(self, profile: Dict[str, Any]) -> Dict[str, Any]:
        user_id = uuid.uuid4()
        spotify_id = profile.get('id')
        name_source = profile.get('display_name') or spotify_id or "spotify_user"
        email = profile.get('email') or f"{spotify_id or 'spotify_user'}@spotify.local"
        username = name_source.replace(' ', '_')[:50]
        display_name = name_source
        self._execute(
            """
            INSERT INTO users (id, email, username, display_name)
            VALUES (%s, %s, %s, %s)
            """,
            (str(user_id), email, username, display_name)
        )
        created = self._fetch_one("SELECT * FROM users WHERE id = %s", (str(user_id),))
        if not created:
            raise RuntimeError("Failed to fetch newly created Spotify user")
        return created

    def _get_db_spotify_tokens(self, user_id: str) -> Optional[Dict[str, Any]]:
        return self._fetch_one(
            "SELECT spotify_id, access_token, refresh_token, token_expires_at FROM spotify_tokens WHERE user_id = %s",
            (user_id,)
        )

    def has_spotify_tokens(self, user_id: str) -> bool:
        return self._get_db_spotify_tokens(user_id) is not None

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
        spotify_id = tokens.get('spotify_id')
        if not spotify_id:
            logger.warning(f"Spotify tokens missing spotify_id for user {user_id}")
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
        if not refreshed or 'access_token' not in refreshed:
            logger.warning(f"Refresh failed for user {user_id}")
            return None
        refreshed['expires_at'] = int(time.time()) + refreshed.get('expires_in', 3600)
        if 'refresh_token' not in refreshed and refresh_token:
            refreshed['refresh_token'] = refresh_token
        self._save_spotify_tokens(user_id, spotify_id, refreshed)
        logger.info(f"Refreshed Spotify token for user {user_id}; expires_at={refreshed['expires_at']}")
        return refreshed.get('access_token')

    def get_spotify_currently_playing(self, user_id: str) -> Optional[Dict[str, Any]]:
        access_token = self._ensure_valid_spotify_access_token(user_id)
        if not access_token:
            logger.warning(f"Cannot fetch now playing; no valid access token for user {user_id}")
            return None
        try:
            now_playing = self.spotify_client.get_currently_playing(access_token)
            logger.debug(f"Fetched now playing for user {user_id}; empty={not bool(now_playing)}")
            return now_playing
        except Exception as e:
            logger.error(f"Error fetching now playing for user {user_id}: {e}")
            return None

    def login_with_spotify(self, code: str, link_user_id: Optional[str] = None, allow_create_if_new: bool = True) -> Optional[str]:
        try:
            result = self.spotify_client.complete_oauth_flow(code)
            if not result or 'user_info' not in result or 'tokens' not in result:
                logger.error("Spotify login failed: empty result or missing fields")
                return None
            profile = result['user_info']
            tokens = result['tokens']
            spotify_id = profile.get('id')
            if not spotify_id:
                logger.error("Spotify login failed: missing spotify_id")
                return None
            images = profile.get('images') or []
            avatar_url = None
            if isinstance(images, list) and images:
                avatar_url = images[0].get('url')

            user: Optional[Dict[str, Any]] = None
            identity = self._get_identity('spotify', spotify_id)

            if link_user_id:
                user = self._get_user_by_id(link_user_id)
                if not user:
                    logger.error(f"Spotify login failed: link_user_id {link_user_id} not found")
                    return None
                if identity and identity['user_id'] != user['id']:
                    old_user_id = identity['user_id']
                    logger.warning(
                        "Reassigning spotify identity %s from user %s to user %s",
                        spotify_id,
                        old_user_id,
                        user['id'],
                    )
                    self._reassign_spotify_identity(old_user_id, user['id'], spotify_id, avatar_url)
                    identity = {'user_id': user['id'], 'provider': 'spotify', 'provider_id': spotify_id}
            else:
                if identity:
                    user = self._get_user_by_id(identity['user_id'])
                if not user:
                    user = self._get_user_by_spotify_id(spotify_id)

            if not user:
                if not allow_create_if_new:
                    logger.warning("Spotify login refused: no existing identity and creation not allowed")
                    return None
                user = self._create_spotify_user(profile)

            tokens['expires_at'] = int(time.time()) + tokens.get('expires_in', 3600)
            self._link_identity(
                user['id'], 'spotify', spotify_id, avatar_url=avatar_url, select_if_none=True
            )
            self._select_identity(user['id'], 'spotify', spotify_id)
            self._save_spotify_tokens(user['id'], spotify_id, tokens)
            # Mark Spotify as enabled for the user once OAuth completes
            try:
                self.update_dashboard_settings(user['id'], spotify_enabled=True)
            except Exception as e:
                logger.warning(f"Failed to update dashboard settings for Spotify enablement: {e}")
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
