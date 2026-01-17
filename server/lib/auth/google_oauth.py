#!/usr/bin/env python3
"""
Google OAuth 2.0 Client
Handles Google OAuth authentication flow without external OAuth libraries
"""
import os
import sys
from pathlib import Path
from typing import Dict, Optional, Any
from urllib.parse import urlencode
import requests

# Add server directory to path for imports
SERVER_DIR = Path(__file__).parent.parent.parent
if str(SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(SERVER_DIR))

from config import Config
from lib.utils.logger import auth_logger as logger


class GoogleOAuthClient:
    """Google OAuth 2.0 client implementation"""
    
    def __init__(self):
        """Initialize Google OAuth client with credentials and endpoints from config"""
        self.client_id = Config.GOOGLE_CLIENT_ID
        self.client_secret = Config.GOOGLE_CLIENT_SECRET
        self.redirect_uri = Config.GOOGLE_REDIRECT_URI
        google_cfg = getattr(Config, 'GOOGLE_CONFIG', None)
        if google_cfg is None:
            # fallback to config.json loading
            import json
            conf_path = Path(__file__).parent.parent.parent / 'conf' / 'dev.json'
            with open(conf_path) as f:
                google_cfg = json.load(f).get('google', {})
        self.authorization_url = google_cfg.get('authorizationUrl', "https://accounts.google.com/o/oauth2/v2/auth")
        self.token_url = google_cfg.get('tokenUrl', "https://oauth2.googleapis.com/token")
        self.user_info_url = google_cfg.get('userInfoUrl', "https://www.googleapis.com/oauth2/v2/userinfo")
        self.scopes = google_cfg.get('scopes', [
            "openid",
            "https://www.googleapis.com/auth/userinfo.email",
            "https://www.googleapis.com/auth/userinfo.profile"
        ])
        if not self.client_id or not self.client_secret:
            raise ValueError("Google OAuth credentials not configured. Set GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET in .env")
    
    def get_authorization_url(self, state: str) -> str:
        """
        Generate Google OAuth authorization URL
        
        Args:
            state: Random string to prevent CSRF attacks (should be stored in session)
        
        Returns:
            Full authorization URL to redirect user to
        
        Example:
            >>> client = GoogleOAuthClient()
            >>> url = client.get_authorization_url('random-state-123')
            >>> # Redirect user to this URL
        """
        params = {
            'client_id': self.client_id,
            'redirect_uri': self.redirect_uri,
            'response_type': 'code',
            'scope': ' '.join(self.scopes),
            'state': state,
            'access_type': 'online',  # We don't need refresh token for Google
            'prompt': 'select_account'  # Let user choose account
        }
        url = f"{self.authorization_url}?{urlencode(params)}"
        logger.info(f"Generated Google OAuth URL with state: {state}")
        return url
    
    def exchange_code_for_tokens(self, code: str) -> Dict[str, Any]:
        """
        Exchange authorization code for access token
        
        Args:
            code: Authorization code from Google callback
        
        Returns:
            Dictionary containing:
            {
                'access_token': str,
                'token_type': 'Bearer',
                'expires_in': int,
                'scope': str,
                'id_token': str (optional)
            }
        
        Raises:
            requests.HTTPError: If token exchange fails
            ValueError: If response is invalid
        
        Example:
            >>> tokens = client.exchange_code_for_tokens('auth-code-from-callback')
            >>> access_token = tokens['access_token']
        """
        data = {
            'code': code,
            'client_id': self.client_id,
            'client_secret': self.client_secret,
            'redirect_uri': self.redirect_uri,
            'grant_type': 'authorization_code'
        }
        
        try:
            logger.info("Exchanging authorization code for access token")
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
            logger.info("✅ Successfully obtained access token from Google")
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
    
    def get_user_info(self, access_token: str) -> Dict[str, Any]:
        """
        Fetch user profile information from Google
        
        Args:
            access_token: Valid Google access token
        
        Returns:
            Dictionary containing user info:
            {
                'id': str,              # Google user ID
                'email': str,           # User's email
                'verified_email': bool, # Email verification status
                'name': str,            # Full name
                'given_name': str,      # First name
                'family_name': str,     # Last name
                'picture': str,         # Profile picture URL
                'locale': str           # User's locale (e.g., 'en')
            }
        
        Raises:
            requests.HTTPError: If API call fails
            ValueError: If response is invalid
        
        Example:
            >>> user_info = client.get_user_info(access_token)
            >>> print(f"User: {user_info['email']}")
        """
        try:
            logger.info("Fetching user info from Google")
            response = requests.get(
                self.user_info_url,
                headers={'Authorization': f'Bearer {access_token}'},
                timeout=10
            )
            response.raise_for_status()
            user_info = response.json()
            required_fields = ['id', 'email']
            for field in required_fields:
                if field not in user_info:
                    raise ValueError(f"Invalid user info response: missing {field}")
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
        """
        Complete entire OAuth flow: exchange code and fetch user info
        
        Args:
            code: Authorization code from Google callback
        
        Returns:
            Dictionary containing both tokens and user info:
            {
                'tokens': {...},
                'user_info': {...}
            }
        
        Raises:
            requests.HTTPError: If any step fails
            ValueError: If response is invalid
        
        Example:
            >>> result = client.complete_oauth_flow('auth-code')
            >>> email = result['user_info']['email']
            >>> access_token = result['tokens']['access_token']
        """
        logger.info("Starting complete OAuth flow")
        
        # Step 1: Exchange code for tokens
        tokens = self.exchange_code_for_tokens(code)
        
        # Step 2: Fetch user info
        user_info = self.get_user_info(tokens['access_token'])
        
        logger.info("✅ Complete OAuth flow successful")
        return {
            'tokens': tokens,
            'user_info': user_info
        }


# =============================================================================
# STANDALONE TESTING
# =============================================================================

if __name__ == '__main__':
    print("\n" + "=" * 70)
    print("TESTING GOOGLE OAUTH CLIENT")
    print("=" * 70 + "\n")
    
    try:
        # Initialize client
        print("1️⃣  Initializing Google OAuth client...")
        client = GoogleOAuthClient()
        client_id_display = client.client_id[:20] + "..." if client.client_id and len(client.client_id) > 20 else client.client_id
        print(f"   Client ID: {client_id_display}")
        print(f"   Redirect URI: {client.redirect_uri}")
        print("   ✅ Client initialized\n")
        
        # Generate authorization URL
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
        print("2. Complete Google login and authorization")
        print("3. Copy the 'code' parameter from the redirect URL")
        print("4. Test token exchange:")
        print("\n   from lib.auth.google_oauth import GoogleOAuthClient")
        print("   client = GoogleOAuthClient()")
        print("   result = client.complete_oauth_flow('YOUR_CODE_HERE')")
        print("   print(result['user_info'])")
        print("\n" + "=" * 70 + "\n")
        
    except ValueError as e:
        print(f"\n❌ Configuration Error: {str(e)}")
        print("\nPlease ensure your .env file has:")
        print("  - GOOGLE_CLIENT_ID")
        print("  - GOOGLE_CLIENT_SECRET")
        print("  - GOOGLE_REDIRECT_URI\n")
        sys.exit(1)
    except Exception as e:
        print(f"\n❌ Unexpected error: {str(e)}")
        sys.exit(1)
