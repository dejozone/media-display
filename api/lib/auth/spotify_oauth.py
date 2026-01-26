#!/usr/bin/env python3
"""
Spotify OAuth 2.0 Client
Handles Spotify OAuth authentication flow without external OAuth libraries
"""
import sys
from pathlib import Path
from typing import Dict, Any
from urllib.parse import urlencode
import requests
import urllib3
from urllib3.exceptions import InsecureRequestWarning

# Add server directory to path for imports
SERVER_DIR = Path(__file__).parent.parent.parent
if str(SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(SERVER_DIR))

from config import Config
from lib.utils.logger import auth_logger as logger

class SpotifyOAuthClient:
    """Spotify OAuth 2.0 client implementation"""

    def __init__(self):
        """Initialize Spotify OAuth client with credentials and endpoints from config"""
        self.client_id = Config.SPOTIFY_CLIENT_ID
        self.client_secret = Config.SPOTIFY_CLIENT_SECRET
        self.redirect_uri = Config.SPOTIFY_REDIRECT_URI
        self.authorization_url = Config.SPOTIFY_AUTH_URL
        self.token_url = Config.SPOTIFY_TOKEN_URL
        self.user_info_url = Config.SPOTIFY_USER_INFO_URL
        self.verify_main = Config.SPOTIFY_API_MAIN_SSL_VERIFY
        self.verify_account = Config.SPOTIFY_API_ACCOUNT_SSL_VERIFY
        self.scopes = Config.SPOTIFY_SCOPE_LIST or [
            "user-read-currently-playing",
            "user-read-playback-state",
            "user-read-email",
            "user-read-private"
        ]
        if not self.verify_main or not self.verify_account:
            # Suppress urllib3 warnings when SSL verification is intentionally disabled via config.
            urllib3.disable_warnings(InsecureRequestWarning)
        if not self.client_id or not self.client_secret:
            raise ValueError("Spotify OAuth credentials not configured. Set SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET in .env")

    def get_authorization_url(self, state: str) -> str:
        params = {
            'client_id': self.client_id,
            'response_type': 'code',
            'redirect_uri': self.redirect_uri,
            'scope': ' '.join(self.scopes),
            'state': state,
            'show_dialog': 'true'
        }
        url = f"{self.authorization_url}?{urlencode(params)}"
        logger.info(f"Generated Spotify OAuth URL with state: {state}")
        return url

    def exchange_code_for_tokens(self, code: str) -> Dict[str, Any]:
        data = {
            'grant_type': 'authorization_code',
            'code': code,
            'redirect_uri': self.redirect_uri,
            'client_id': self.client_id,
            'client_secret': self.client_secret
        }
        try:
            logger.info("Exchanging authorization code for access and refresh tokens")
            response = requests.post(
                self.token_url,
                data=data,
                headers={'Content-Type': 'application/x-www-form-urlencoded'},
                timeout=10,
                verify=self.verify_account,
            )
            response.raise_for_status()
            tokens = response.json()
            if 'access_token' not in tokens:
                raise ValueError("Invalid token response: missing access_token")
            logger.info("✅ Successfully obtained access token from Spotify")
            return tokens
        except requests.HTTPError as e:
            logger.error(f"❌ Token exchange failed: {e.response.status_code} - {e.response.text}")
            raise
        except requests.RequestException as e:
            logger.error(f"❌ Network error during token exchange: {str(e)}")
            raise
        except ValueError as e:
            logger.error(f"❌ Invalid token response: {str(e)}")
            raise

    def refresh_access_token(self, refresh_token: str) -> Dict[str, Any]:
        data = {
            'grant_type': 'refresh_token',
            'refresh_token': refresh_token,
            'client_id': self.client_id,
            'client_secret': self.client_secret
        }
        try:
            logger.info("Refreshing Spotify access token")
            response = requests.post(
                self.token_url,
                data=data,
                headers={'Content-Type': 'application/x-www-form-urlencoded'},
                timeout=10,
                verify=self.verify_account,
            )
            response.raise_for_status()
            tokens = response.json()
            if 'access_token' not in tokens:
                raise ValueError("Invalid token response: missing access_token")
            logger.info("✅ Successfully refreshed access token from Spotify")
            return tokens
        except requests.HTTPError as e:
            logger.error(f"❌ Token refresh failed: {e.response.status_code} - {e.response.text}")
            raise
        except requests.RequestException as e:
            logger.error(f"❌ Network error during token refresh: {str(e)}")
            raise
        except ValueError as e:
            logger.error(f"❌ Invalid token response: {str(e)}")
            raise

    def get_user_info(self, access_token: str) -> Dict[str, Any]:
        try:
            logger.info("Fetching user info from Spotify")
            response = requests.get(
                self.user_info_url,
                headers={'Authorization': f'Bearer {access_token}'},
                timeout=10,
                verify=self.verify_main,
            )
            response.raise_for_status()
            user_info = response.json()
            if 'id' not in user_info:
                raise ValueError("Invalid user info response: missing id")
            logger.info(f"✅ Successfully fetched user info for: {user_info.get('email', 'unknown')}")
            return user_info
        except requests.HTTPError as e:
            logger.error(f"❌ User info fetch failed: {e.response.status_code} - {e.response.text}")
            raise
        except requests.RequestException as e:
            logger.error(f"❌ Network error fetching user info: {str(e)}")
            raise
        except ValueError as e:
            logger.error(f"❌ Invalid user info response: {str(e)}")
            raise

    def _get_player_state(self, access_token: str) -> Dict[str, Any]:
        """Fetch overall player state (device + playback status), even if no track."""
        response = requests.get(
            "https://api.spotify.com/v1/me/player",
            headers={'Authorization': f'Bearer {access_token}'},
            timeout=10,
            verify=self.verify_main,
        )
        if response.status_code == 204:
            return {}
        response.raise_for_status()
        return response.json()

    def get_currently_playing(self, access_token: str) -> Dict[str, Any]:
        """Fetch currently playing track for the user.

        Includes device and playback status, falling back to player state when the
        currently-playing endpoint returns 204 or omits device info.
        """
        try:
            logger.info("Fetching currently playing from Spotify")
            response = requests.get(
                "https://api.spotify.com/v1/me/player/currently-playing",
                headers={'Authorization': f'Bearer {access_token}'},
                timeout=10,
                verify=self.verify_main,
            )

            # If nothing is playing, try the broader player endpoint to capture device/status
            if response.status_code == 204:
                logger.info("Currently playing returned 204; fetching player state for device/status")
                return self._get_player_state(access_token)

            response.raise_for_status()
            data = response.json()

            # Backfill device/status if missing
            needs_device = 'device' not in data or data.get('device') is None
            needs_status = 'is_playing' not in data
            if needs_device or needs_status:
                try:
                    player_state = self._get_player_state(access_token)
                    if needs_device:
                        data['device'] = player_state.get('device')
                    if needs_status and 'is_playing' in player_state:
                        data['is_playing'] = player_state.get('is_playing')
                except Exception:
                    # Best-effort; keep original data if fallback fails
                    pass

            return data
        except requests.HTTPError as e:
            logger.error(f"❌ Now playing fetch failed: {e.response.status_code} - {e.response.text}")
            raise
        except requests.RequestException as e:
            logger.error(f"❌ Network error fetching now playing: {str(e)}")
            raise

    def complete_oauth_flow(self, code: str) -> Dict[str, Any]:
        logger.info("Starting complete Spotify OAuth flow")
        tokens = self.exchange_code_for_tokens(code)
        user_info = self.get_user_info(tokens['access_token'])
        logger.info("✅ Complete Spotify OAuth flow successful")
        return {
            'tokens': tokens,
            'user_info': user_info
        }

# =============================================================================
# STANDALONE TESTING
# =============================================================================

if __name__ == '__main__':
    print("\n" + "=" * 70)
    print("TESTING SPOTIFY OAUTH CLIENT")
    print("=" * 70 + "\n")
    try:
        print("1️⃣  Initializing Spotify OAuth client...")
        client = SpotifyOAuthClient()
        client_id_display = client.client_id[:20] + "..." if client.client_id and len(client.client_id) > 20 else client.client_id
        print(f"   Client ID: {client_id_display}")
        print(f"   Redirect URI: {client.redirect_uri}")
        print("   ✅ Client initialized\n")
        print("2️⃣  Generating authorization URL...")
        test_state = "test-state-12345"
        auth_url = client.get_authorization_url(test_state)
        print(f"   State: {test_state}")
        print(f"   URL: {auth_url[:80]}...")
        print("   ✅ Authorization URL generated\n")
        print("=" * 70)
        print("📋 MANUAL TESTING STEPS")
        print("=" * 70)
        print("\nTo complete OAuth flow testing:")
        print("\n1. Open this URL in your browser:")
        print(f"\n   {auth_url}\n")
        print("2. Complete Spotify login and authorization")
        print("3. Copy the 'code' parameter from the redirect URL")
        print("4. Test token exchange:")
        print("\n   from lib.auth.spotify_oauth import SpotifyOAuthClient")
        print("   client = SpotifyOAuthClient()")
        print("   result = client.complete_oauth_flow('YOUR_CODE_HERE')")
        print("   print(result['user_info'])")
        print("\n" + "=" * 70 + "\n")
    except ValueError as e:
        print(f"\n❌ Configuration Error: {str(e)}")
        print("\nPlease ensure your .env file has:")
        print("  - SPOTIFY_CLIENT_ID")
        print("  - SPOTIFY_CLIENT_SECRET")
        print("  - SPOTIFY_REDIRECT_URI\n")
        sys.exit(1)
    except Exception as e:
        print(f"\n❌ Unexpected error: {str(e)}")
        sys.exit(1)
