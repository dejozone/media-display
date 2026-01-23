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

    def ensure_dashboard_settings(self, user_id: str, *, spotify_enabled: Optional[bool] = None, sonos_enabled: Optional[bool] = None) -> None:
        existing = self.get_dashboard_settings(user_id)
        if existing:
            self.update_dashboard_settings(user_id, spotify_enabled=spotify_enabled, sonos_enabled=sonos_enabled)
            return
        self._execute(
            """
            INSERT INTO dashboard_settings (user_id, spotify_enabled, sonos_enabled)
            VALUES (%s, %s, %s)
            """,
            (user_id, spotify_enabled, sonos_enabled),
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
                    user['id'], 'google', google_id, avatar_url=avatar_url
                )
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

    def delete_identity_by_provider(self, user_id: str, provider: str) -> None:
        self._execute(
            "DELETE FROM identities WHERE user_id = %s AND provider = %s",
            (str(user_id), provider),
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
        # Deprecated - identities no longer store avatar_url
        # Avatars are now managed via the avatars table
        pass

    def select_identity_by_provider(self, user_id: str, provider: str) -> None:
        # Avatar selection now handled via avatars table - this method is deprecated
        # Find the avatar with this provider and select it
        identity = self._fetch_one(
            "SELECT provider_id FROM identities WHERE user_id = %s AND provider = %s ORDER BY created_at DESC LIMIT 1",
            (str(user_id), provider),
        )
        if not identity:
            return
        
        # Find and select the avatar with this provider_id
        avatar = self._fetch_one(
            "SELECT id FROM avatars WHERE user_id = %s AND provider_id = %s",
            (str(user_id), identity['provider_id']),
        )
        if avatar:
            self.update_avatar_selection(user_id, avatar['id'])

    def _link_identity(self, user_id: str, provider: str, provider_id: str, avatar_url: Optional[str] = None) -> None:
        self._execute(
            """
            INSERT INTO identities (user_id, provider, provider_id)
            VALUES (%s, %s, %s)
            ON CONFLICT (provider, provider_id) DO UPDATE SET
                user_id = EXCLUDED.user_id
            """,
            (str(user_id), provider, provider_id),
        )
        
        # Create avatar record from provider if we have an avatar_url
        if avatar_url:
            # Check if provider avatar already exists
            existing = self._fetch_one(
                "SELECT id FROM avatars WHERE user_id = %s AND source = 'provider' AND provider_id = %s",
                (str(user_id), provider_id),
            )
            if not existing:
                # Check if user has any avatars
                has_avatars = self._fetch_one(
                    "SELECT 1 FROM avatars WHERE user_id = %s LIMIT 1",
                    (str(user_id),),
                )
                is_selected = has_avatars is None
                
                self._execute(
                    """
                    INSERT INTO avatars (user_id, url, source, provider_id, is_selected)
                    VALUES (%s, %s, 'provider', %s, %s)
                    """,
                    (str(user_id), avatar_url, provider_id, is_selected),
                )

    def _reassign_spotify_identity(self, old_user_id: str, new_user_id: str, spotify_id: str, avatar_url: Optional[str]) -> None:
        # Move identity and tokens to the new user, then remove the old user record
        self._execute(
            """
            UPDATE identities
            SET user_id = %s
            WHERE provider = 'spotify' AND provider_id = %s
            """,
            (str(new_user_id), spotify_id),
        )
        # Move any avatars associated with this provider
        if avatar_url:
            self._execute(
                """
                UPDATE avatars
                SET user_id = %s
                WHERE provider_id = %s
                """,
                (str(new_user_id), spotify_id),
            )
        self._execute(
            """
            UPDATE spotify_tokens
            SET user_id = %s
            WHERE user_id = %s
            """,
            (str(new_user_id), str(old_user_id)),
        )
        # Avatar selection now handled via avatars table
        # Remove old user row now that associations are moved
        self._execute("DELETE FROM users WHERE id = %s", (str(old_user_id),))

    # _select_identity method removed - avatar selection now handled via avatars table

    def _get_selected_avatar_url(self, user_id: str) -> Optional[str]:
        row = self._fetch_one(
            """
            SELECT url
            FROM avatars
            WHERE user_id = %s AND is_selected = TRUE
            ORDER BY created_at ASC
            LIMIT 1
            """,
            (str(user_id),),
        )
        if row:
            return row['url']
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

    def delete_spotify_tokens(self, user_id: str) -> None:
        self._execute(
            "DELETE FROM spotify_tokens WHERE user_id = %s",
            (str(user_id),),
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

    def get_spotify_access_token_with_expiry(self, user_id: str) -> Optional[Dict[str, Any]]:
        """Get Spotify access token and its expiry timestamp (epoch seconds)."""
        tokens = self._get_db_spotify_tokens(user_id)
        if not tokens:
            logger.warning(f"No Spotify tokens cached for user {user_id}")
            return None
        spotify_id = tokens.get('spotify_id')
        if not spotify_id:
            logger.warning(f"Spotify tokens missing spotify_id for user {user_id}")
            return None
        now = int(time.time())
        expires_at = tokens.get('token_expires_at', 0)
        if expires_at > now + 30:
            logger.debug(f"Using cached Spotify access token for user {user_id}")
            return {
                'access_token': tokens.get('access_token'),
                'expires_at': expires_at,
            }
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
        return {
            'access_token': refreshed.get('access_token'),
            'expires_at': refreshed['expires_at'],
        }

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

    def login_with_spotify(self, code: str, link_user_id: Optional[str] = None, allow_create_if_new: bool = True) -> Tuple[Optional[str], Optional[str]]:
        try:
            result = self.spotify_client.complete_oauth_flow(code)
            if not result or 'user_info' not in result or 'tokens' not in result:
                logger.error("Spotify login failed: empty result or missing fields")
                return None, 'spotify_login_failed'
            profile = result['user_info']
            tokens = result['tokens']
            spotify_id = profile.get('id')
            if not spotify_id:
                logger.error("Spotify login failed: missing spotify_id")
                return None, 'spotify_login_failed'
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
                    return None, 'spotify_login_failed'
                if identity and identity['user_id'] != user['id']:
                    logger.warning(
                        "Spotify identity %s already linked to different user %s; rejecting for user %s",
                        spotify_id,
                        identity['user_id'],
                        user['id'],
                    )
                    return None, 'spotify_identity_in_use'
            else:
                if identity:
                    user = self._get_user_by_id(identity['user_id'])
                if not user:
                    user = self._get_user_by_spotify_id(spotify_id)

            if not user:
                if not allow_create_if_new:
                    logger.warning("Spotify login refused: no existing identity and creation not allowed")
                    return None, 'spotify_login_failed'
                user = self._create_spotify_user(profile)

            tokens['expires_at'] = int(time.time()) + tokens.get('expires_in', 3600)
            self._link_identity(
                user['id'], 'spotify', spotify_id, avatar_url=avatar_url
            )
            self._save_spotify_tokens(user['id'], spotify_id, tokens)
            # Mark Spotify as enabled for the user once OAuth completes
            try:
                self.update_dashboard_settings(user['id'], spotify_enabled=True)
            except Exception as e:
                logger.warning(f"Failed to update dashboard settings for Spotify enablement: {e}")
            token = self.create_jwt(user, provider='spotify')
            return token, None
        except Exception as e:
            logger.error(f"Spotify login failed: {str(e)}")
            return None, 'spotify_login_failed'

    def get_account_payload(self, user_id: str) -> Dict[str, Any]:
        user = self.get_user(user_id)
        if not user:
            return {}
        identities = self.get_identities(user_id) or []
        
        # Get provider avatars from avatars table
        avatars = self.get_avatars(user_id, limit=50)
        provider_avatars = {}
        provider_avatar_list = []
        
        for avatar in avatars:
            if avatar.get('source') == 'provider' and avatar.get('provider_id'):
                # Find the provider for this avatar
                identity = next((i for i in identities if i.get('provider_id') == avatar.get('provider_id')), None)
                if identity:
                    provider_name = identity.get('provider')
                    provider_avatars[provider_name] = avatar.get('url')
                    provider_avatar_list.append({
                        'provider': provider_name,
                        'provider_id': avatar.get('provider_id'),
                        'avatar_url': avatar.get('url'),
                    })
        
        # Get selected avatar from avatars table
        avatar_url = self._get_selected_avatar_url(user_id)
        if not avatar_url and avatars:
            avatar_url = avatars[0].get('url')
        
        # Get primary provider (first identity)
        provider = identities[0].get('provider') if identities else None
        spotify_connected = self.has_spotify_tokens(user_id)
        return {
            'id': user.get('id'),
            'email': user.get('email'),
            'username': user.get('username'),
            'display_name': user.get('display_name'),
            'name': user.get('display_name') or user.get('username') or user.get('email'),
            'provider': provider,
            'provider_selected': provider,
            'spotifyConnected': spotify_connected,
            'avatar_url': avatar_url,
            'provider_avatars': provider_avatars,
            'provider_avatar_list': provider_avatar_list,
        }

    # =============================================================================
    # Avatar management methods
    # =============================================================================
    
    def get_avatars(self, user_id: str, limit: int = 50) -> List[Dict[str, Any]]:
        """Get all avatars for a user."""
        return self._fetch_all(
            """
            SELECT id, user_id, url, source, provider_id, is_selected, file_size, mime_type, created_at, updated_at
            FROM avatars
            WHERE user_id = %s
            ORDER BY is_selected DESC, created_at DESC
            LIMIT %s
            """,
            (str(user_id), limit),
        )
    
    def get_avatar_by_id(self, user_id: str, avatar_id: str) -> Optional[Dict[str, Any]]:
        """Get a specific avatar by ID."""
        return self._fetch_one(
            """
            SELECT id, user_id, url, source, provider_id, is_selected, file_size, mime_type, created_at, updated_at
            FROM avatars
            WHERE user_id = %s AND id = %s
            """,
            (str(user_id), str(avatar_id)),
        )
    
    def get_avatar_by_url(self, user_id: str, avatar_url: str) -> Optional[Dict[str, Any]]:
        """Get a specific avatar by URL."""
        return self._fetch_one(
            """
            SELECT id, user_id, url, source, provider_id, is_selected, file_size, mime_type, created_at, updated_at
            FROM avatars
            WHERE user_id = %s AND url = %s
            """,
            (str(user_id), avatar_url),
        )
    
    def create_avatar(
        self,
        user_id: str,
        url: str,
        source: str,
        provider_id: Optional[str] = None,
        is_selected: bool = False,
        file_size: Optional[int] = None,
        mime_type: Optional[str] = None,
    ) -> Dict[str, Any]:
        """Create a new avatar record."""
        # If this is the first avatar or is_selected=True, ensure only one is selected
        if is_selected:
            self._execute(
                "UPDATE avatars SET is_selected = FALSE WHERE user_id = %s",
                (str(user_id),),
            )
        
        self._execute(
            """
            INSERT INTO avatars (user_id, url, source, provider_id, is_selected, file_size, mime_type)
            VALUES (%s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (user_id, url) DO UPDATE SET
                is_selected = EXCLUDED.is_selected,
                file_size = COALESCE(EXCLUDED.file_size, avatars.file_size),
                mime_type = COALESCE(EXCLUDED.mime_type, avatars.mime_type),
                updated_at = CURRENT_TIMESTAMP
            RETURNING id
            """,
            (str(user_id), url, source, provider_id, is_selected, file_size, mime_type),
        )
        
        result = self.get_avatar_by_url(user_id, url)
        if not result:
            raise RuntimeError(f"Failed to fetch created avatar for user {user_id}")
        return result
    
    def update_avatar_selection(self, user_id: str, avatar_id: str) -> bool:
        """Set an avatar as selected, deselecting all others."""
        # Verify the avatar exists and belongs to the user
        avatar = self.get_avatar_by_id(user_id, avatar_id)
        if not avatar:
            return False
        
        # Deselect all other avatars
        self._execute(
            "UPDATE avatars SET is_selected = FALSE WHERE user_id = %s",
            (str(user_id),),
        )
        
        # Select the target avatar
        self._execute(
            "UPDATE avatars SET is_selected = TRUE, updated_at = CURRENT_TIMESTAMP WHERE user_id = %s AND id = %s",
            (str(user_id), str(avatar_id)),
        )
        
        return True
    
    def delete_avatar(self, user_id: str, avatar_id: str) -> bool:
        """Delete an avatar. If it was selected, auto-select another."""
        avatar = self.get_avatar_by_id(user_id, avatar_id)
        if not avatar:
            return False
        
        was_selected = avatar.get('is_selected', False)
        
        self._execute(
            "DELETE FROM avatars WHERE user_id = %s AND id = %s",
            (str(user_id), str(avatar_id)),
        )
        
        # If deleted avatar was selected, auto-select the most recent one
        if was_selected:
            remaining = self.get_avatars(user_id, limit=1)
            if remaining:
                self.update_avatar_selection(user_id, remaining[0]['id'])
        
        return True
    
    def get_selected_avatar(self, user_id: str) -> Optional[Dict[str, Any]]:
        """Get the currently selected avatar for a user."""
        return self._fetch_one(
            """
            SELECT id, url, source, provider_id, is_selected, file_size, mime_type, created_at, updated_at
            FROM avatars
            WHERE user_id = %s AND is_selected = TRUE
            LIMIT 1
            """,
            (str(user_id),),
        )

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
