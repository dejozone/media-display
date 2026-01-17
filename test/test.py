
import sys
from pathlib import Path
server_dir = Path(__file__).parent.parent / 'server'
sys.path.insert(0, str(server_dir.resolve()))
from lib.auth.google_oauth import GoogleOAuthClient
from urllib.parse import unquote

oauth_code = "4%2F0ASc3gC02_eYyGiIeUWl8IdqSymnjy2Dg-LECD-QRvVEwPzq7hXAdpVoHqQAGAqKYlKPsCw"
decoded_code = unquote(oauth_code)
client = GoogleOAuthClient()
result = client.complete_oauth_flow(decoded_code)
print(result['user_info'])