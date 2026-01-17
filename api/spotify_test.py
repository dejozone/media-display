import sys
from pathlib import Path
from urllib.parse import unquote

# Ensure server directory is in sys.path for imports
server_dir = Path(__file__).parent.parent / 'server'
sys.path.insert(0, str(server_dir.resolve()))

from lib.auth.spotify_oauth import SpotifyOAuthClient

# Replace with your actual URL-encoded Spotify OAuth code
oauth_code = "AQBtuXVmgdAiRUmWuMmWui4D2WtDdndnPh2vYEbgS4HNWMdpYOrbPMWG6SjekUUhwE9r7xpzz9ndGArIfuGPN1SPXoRYOaPH5Jt63PYDIlAI1_WGl0mD2_SUl5VKVtb9g8E9ACCSdimidQ2I17hHhGhjMbVG_T809DC9IMX_YHvl7sg44RKTzWbhJbQf3bkeeuc8ZFORIU8XZ0hYBMfzyZ0hdP6gpX1cmLT2eEktb7bfM723U0cvnKwUTz115Hx3Q0m2s0AqNJszatbFloC11-0R5zZ8sAuVLAUec5MSOOzZ0Iv6taDLiCZ8ackOfuPGQEZYJKZ799nuP1vapfuKlAUP_XuTfSzzJA-dWQ"
decoded_code = unquote(oauth_code)

client = SpotifyOAuthClient()
result = client.complete_oauth_flow(decoded_code)
print(result['user_info'])
