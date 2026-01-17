import sys

from lib.auth.spotify_oauth import SpotifyOAuthClient


if __name__ == "__main__":
    print("\n================================================================")
    print("TESTING SPOTIFY OAUTH CLIENT - AUTHORIZATION URL")
    print("================================================================\n")
    try:
        client = SpotifyOAuthClient()
        test_state = "test-state-12345"
        auth_url = client.get_authorization_url(test_state)
        print(f"1️⃣  Open this URL in your browser to start Spotify OAuth:")
        print(f"\n   {auth_url}\n")
        print("2️⃣  Complete Spotify login and authorization")
        print("3️⃣  Copy the 'code' parameter from the redirect URL")
        print("4️⃣  Use this code to test token exchange in spotify_test.py")
    except Exception as e:
        print(f"❌ Error: {str(e)}")
        sys.exit(1)
