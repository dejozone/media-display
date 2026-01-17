#!/usr/bin/env python3
"""
Spotify OAuth 2.0 Client
Handles Spotify OAuth authentication flow without external OAuth libraries
"""
import os
import sys
from pathlib import Path
from typing import Dict, Any
from urllib.parse import urlencode
import requests

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
        spotify_cfg = getattr(Config, 'SPOTIFY_CONFIG', None)
        if spotify_cfg is None:
            import json
            conf_path = Path(__file__).parent.parent.parent / 'conf' / 'dev.json'
            with open(conf_path) as f:
                spotify_cfg = json.load(f).get('spotify', {})
        self.authorization_url = spotify_cfg.get('authorizationUrl', "https://accounts.spotify.com/authorize")
        self.token_url = spotify_cfg.get('tokenUrl', "https://accounts.spotify.com/api/token")
        self.user_info_url = spotify_cfg.get('userInfoUrl', "https://api.spotify.com/v1/me")
        self.scopes = spotify_cfg.get('scopes', [
            "user-read-currently-playing",
            "user-read-playback-state",
            "user-read-email",
            "user-read-private"
        ])
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
                timeout=10
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
                timeout=10
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
                timeout=10
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
