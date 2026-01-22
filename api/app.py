#!/usr/bin/env python3
"""
Flask API for OAuth authentication and JWT management
"""
from flask import Flask, request, jsonify, g, send_from_directory, redirect
from functools import wraps
import secrets
from flask_cors import CORS
import re
from lib.auth.auth_manager import AuthManager
from config import Config
from lib.utils.logger import auth_logger, server_logger
from lib.utils.avatar import validate_avatar_file, get_mime_type, sanitize_avatar_filename

app = Flask(__name__)
CORS(app, origins=Config.CORS_ORIGINS)
auth_manager = AuthManager()
email_re = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
ASSETS_DIR = Config.ASSETS_ROOT
ALLOWED_IMAGE_EXT = Config.ALLOWED_IMAGE_EXTENSIONS
MAX_AVATAR_UPLOAD = Config.MAX_AVATAR_UPLOAD_BYTES


def require_auth(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        auth_header = request.headers.get('Authorization', '')
        if not auth_header.startswith('Bearer '):
            auth_logger.warning("Missing or invalid Authorization header")
            return jsonify({'error': 'Unauthorized'}), 401
        token = auth_header.split(' ', 1)[1]
        payload = auth_manager.validate_jwt(token)
        if not payload or 'sub' not in payload:
            auth_logger.warning("JWT validation failed or missing sub")
            return jsonify({'error': 'Unauthorized'}), 401
        g.user_id = payload['sub']
        g.user_payload = payload
        return f(*args, **kwargs)
    return wrapper

# =============================================================================
# Authentication Management API
# =============================================================================

@app.route('/api/auth/google/url')
def google_auth_url():
    state = secrets.token_urlsafe(16)
    url = auth_manager.google_client.get_authorization_url(state)
    return jsonify({'url': url, 'state': state})

@app.route('/api/auth/spotify/url')
def spotify_auth_url():
    auth_header = request.headers.get('Authorization', '')
    link_user_id = None
    state = None

    if auth_header.startswith('Bearer '):
        token = auth_header.split(' ', 1)[1]
        payload = auth_manager.validate_jwt(token)
        if payload and 'sub' in payload:
            link_user_id = payload['sub']
            state = auth_manager.create_state_token(user_id=link_user_id)
        else:
            auth_logger.warning("Spotify auth URL: invalid bearer token; falling back to unauthenticated flow")

    # If unauthenticated, allow identity-only login later; no link_user_id and optional state
    if state is None:
        state = auth_manager.create_state_token()

    url = auth_manager.spotify_client.get_authorization_url(state)
    return jsonify({'url': url, 'state': state, 'scope': auth_manager.spotify_client.scopes})

@app.route('/api/auth/google/callback')
def google_callback():
    code = request.args.get('code')
    if not code:
        return jsonify({'error': 'Missing code'}), 400
    token = auth_manager.login_with_google(code)
    if not token:
        return jsonify({'error': 'Google OAuth failed'}), 401
    frontend = Config.FRONTEND_BASE_URL
    # Redirect back to frontend with JWT; frontend should store token and continue.
    return redirect(f"{frontend}/oauth/google/callback?jwt={token}")

@app.route('/api/auth/spotify/callback')
def spotify_callback():
    code = request.args.get('code')
    if not code:
        return jsonify({'error': 'Missing code'}), 400
    state = request.args.get('state')
    link_user_id = None
    allow_create = True  # allow new user creation by default for Spotify-only signups
    if state:
        link_user_id = auth_manager.verify_state_token(state)
        if not link_user_id:
            auth_logger.warning("Spotify callback received invalid state; proceeding without linking")
    else:
        auth_logger.warning("Spotify callback missing state; attempting identity-based login only")

    token, err = auth_manager.login_with_spotify(code, link_user_id=link_user_id, allow_create_if_new=allow_create)
    if err == 'spotify_identity_in_use':
        message = 'This Spotify account is already linked to another user.'
        frontend = Config.FRONTEND_BASE_URL
        target = f"{frontend}/oauth/spotify/callback?error={err}&message={message}"
        return redirect(target)
    if not token:
        return jsonify({'error': 'Spotify OAuth failed'}), 401
    frontend = Config.FRONTEND_BASE_URL
    state_param = request.args.get('state')
    return redirect(f"{frontend}/oauth/spotify/callback?jwt={token}" + (f"&state={state_param}" if state_param else ""))


@app.route('/api/auth/<provider>/callback')
def api_auth_callback(provider: str):
    code = request.args.get('code')
    if not code:
        return jsonify({'error': 'Missing code'}), 400

    if provider == 'google':
        token = auth_manager.login_with_google(code)
    elif provider == 'spotify':
        state_param = request.args.get('state')
        link_user_id = None
        allow_create = True  # permit creation when logging in directly with Spotify
        if state_param:
            link_user_id = auth_manager.verify_state_token(state_param)
            if not link_user_id:
                auth_logger.warning("Spotify provider callback invalid state; proceeding without linking")
        else:
            auth_logger.warning("Spotify provider callback missing state; attempting identity-based login only")
        token, err = auth_manager.login_with_spotify(code, link_user_id=link_user_id, allow_create_if_new=allow_create)
    else:
        return jsonify({'error': 'Unsupported provider'}), 400

    if err == 'spotify_identity_in_use':
        message = 'This Spotify account is already linked to another user.'
        frontend = Config.FRONTEND_BASE_URL
        target = f"{frontend}/oauth/{provider}/callback?error={err}&message={message}"
        return redirect(target)
    if not token:
        return jsonify({'error': f'{provider.capitalize()} OAuth failed'}), 401
    frontend = Config.FRONTEND_BASE_URL
    state_param = request.args.get('state')
    return redirect(f"{frontend}/oauth/{provider}/callback?jwt={token}" + (f"&state={state_param}" if state_param else ""))

@app.route('/api/auth/validate', methods=['POST', 'GET'])
def validate_jwt():
    token = None
    if request.method == 'POST':
        data = request.get_json()
        token = data.get('jwt') if data else None
    else:
        auth_header = request.headers.get('Authorization', '')
        if auth_header.startswith('Bearer '):
            token = auth_header.split(' ', 1)[1]

    if not token:
        auth_logger.warning("Validation failed: missing JWT")
        return jsonify({'error': 'Missing JWT'}), 400
    payload = auth_manager.validate_jwt(token)
    if not payload:
        auth_logger.warning("Validation failed: invalid or expired JWT")
        return jsonify({'error': 'Invalid or expired JWT'}), 401
    return jsonify({'valid': True, 'payload': payload})


# =============================================================================
# User Management API
# =============================================================================

@app.route('/api/users/me')
@require_auth
def user_me():
    user = auth_manager.get_user(g.user_id)
    if not user:
        return jsonify({'error': 'User not found'}), 404

    identities = auth_manager.get_identities(g.user_id) or []
    provider = identities[0].get('provider') if identities else None
    
    # Get provider avatars from avatars table
    avatars = auth_manager.get_avatars(g.user_id, limit=50)
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
    selected_avatar = auth_manager._fetch_one(
        "SELECT url FROM avatars WHERE user_id = %s AND is_selected = TRUE ORDER BY created_at DESC LIMIT 1",
        (str(g.user_id),),
    )
    avatar_url = selected_avatar['url'] if selected_avatar else None
    if not avatar_url and avatars:
        avatar_url = avatars[0].get('url')
    
    # spotify_connected = auth_manager.has_spotify_tokens(g.user_id)

    return jsonify({'user': {
        'id': user.get('id'),
        'email': user.get('email'),
        'username': user.get('username'),
        'display_name': user.get('display_name'),
        'name': user.get('display_name') or user.get('username') or user.get('email'),
        'provider': provider,
        'provider_selected': provider,
        # 'spotify_connected': spotify_connected,
        'avatar_url': avatar_url,
        'provider_avatars': provider_avatars,
        'provider_avatar_list': provider_avatar_list,
    }})


@app.route('/api/users/<user_id>/settings', methods=['GET'])
@require_auth
def get_settings(user_id: str):
    # Enforce that the path user matches the JWT subject
    if user_id != g.user_id:
        return jsonify({'error': 'Forbidden'}), 403
    
    settings = auth_manager.get_dashboard_settings(g.user_id) or {}
    return jsonify({'settings': settings})


@app.route('/api/users/<user_id>/settings', methods=['PUT', 'PATCH'])
@require_auth
def update_settings(user_id: str):
    # Enforce that the path user matches the JWT subject
    if user_id != g.user_id:
        return jsonify({'error': 'Forbidden'}), 403
    
    data = request.get_json() or {}
    if not isinstance(data, dict):
        return jsonify({'error': 'Invalid payload'}), 400

    spotify_enabled = data.get('spotify_enabled') if 'spotify_enabled' in data else None
    sonos_enabled = data.get('sonos_enabled') if 'sonos_enabled' in data else None

    if spotify_enabled is None and sonos_enabled is None:
        return jsonify({'error': 'No settings provided'}), 400

    updated = auth_manager.update_dashboard_settings(
        g.user_id,
        spotify_enabled=spotify_enabled,
        sonos_enabled=sonos_enabled,
    ) or {}

    return jsonify({'settings': updated})


@app.route('/api/users/<user_id>/services/<service>', methods=['DELETE', 'POST'])
@require_auth
def manage_service(user_id: str, service: str):
    # Enforce that the path user matches the JWT subject
    if user_id != g.user_id:
        return jsonify({'error': 'Forbidden'}), 403

    service = service.lower()
    if service not in {'spotify', 'sonos'}:
        return jsonify({'error': 'Unsupported service'}), 400

    if request.method == 'DELETE':
        if service == 'spotify':
            auth_manager.delete_identity_by_provider(g.user_id, 'spotify')
            auth_manager.delete_spotify_tokens(g.user_id)
            auth_manager.update_dashboard_settings(g.user_id, spotify_enabled=False)
        elif service == 'sonos':
            auth_manager.update_dashboard_settings(g.user_id, sonos_enabled=False)
    else:  # POST
        if service == 'spotify':
            auth_manager.update_dashboard_settings(g.user_id, spotify_enabled=True)
        elif service == 'sonos':
            auth_manager.ensure_dashboard_settings(g.user_id, sonos_enabled=True)

    settings = auth_manager.get_dashboard_settings(g.user_id) or {}
    account = auth_manager.get_account_payload(g.user_id)
    return jsonify({'settings': settings, 'user': account}), 200


@app.route('/api/users/<user_id>', methods=['PUT', 'PATCH'])
@require_auth
def update_user(user_id: str):
    # Enforce that the path user matches the JWT subject
    if user_id != g.user_id:
        return jsonify({'error': 'Forbidden'}), 403
    
    data = request.get_json() or {}
    if not isinstance(data, dict):
        return jsonify({'error': 'Invalid payload'}), 400

    email = data.get('email')
    username = data.get('username')
    display_name = data.get('display_name')
    avatar_url = data.get('avatar_url')
    avatar_provider = data.get('avatar_provider')

    if email and not email_re.match(email):
        return jsonify({'error': 'Invalid email format'}), 400

    if username and auth_manager.username_exists(username, exclude_user_id=g.user_id):
        return jsonify({'error': 'Username already taken'}), 409

    updated = auth_manager.update_user(
        g.user_id,
        email=email,
        username=username,
        display_name=display_name,
    )
    if not updated:
        return jsonify({'error': 'Update failed'}), 400

    if avatar_provider:
        auth_manager.select_identity_by_provider(g.user_id, avatar_provider)

    if avatar_url is not None:
        auth_manager.update_identity_avatar(g.user_id, avatar_url)

    identities = auth_manager.get_identities(g.user_id) or []
    
    # Get provider avatars from avatars table
    avatars = auth_manager.get_avatars(g.user_id, limit=50)
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
    selected_avatar = auth_manager._fetch_one(
        "SELECT url FROM avatars WHERE user_id = %s AND is_selected = TRUE ORDER BY created_at DESC LIMIT 1",
        (str(g.user_id),),
    )
    chosen_avatar = selected_avatar['url'] if selected_avatar else None
    if not chosen_avatar:
        chosen_avatar = avatar_url or (avatars[0].get('url') if avatars else None)
    
    selected_provider = identities[0].get('provider') if identities else None

    return jsonify({
        'user': {
            **updated,
            'avatar_url': chosen_avatar,
            'provider_avatars': provider_avatars,
            'provider_avatar_list': provider_avatar_list,
            'provider': selected_provider,
            'provider_selected': selected_provider,
        }
    }), 200


@app.route('/api/users/<user_id>/services/<service>/now-playing', methods=['GET'])
@require_auth
def spotify_now_playing(user_id: str, service: str):
    # Enforce that the path user matches the JWT subject
    if user_id != g.user_id:
        return jsonify({'error': 'Forbidden'}), 403
    
    service = service.lower()
    if service != 'spotify':
        return jsonify({'error': 'Unsupported service'}), 400
    
    server_logger.debug(f"/api/users/{user_id}/services/{service}/now-playing requested by user_id={g.user_id}")
    data = auth_manager.get_spotify_currently_playing(g.user_id)
    if data is None:
        server_logger.warning("Now-playing fetch failed: no tokens or refresh failure")
        return jsonify({'error': 'spotify_not_connected_or_token_invalid', 'code': 'ERR_SPOTIFY_4001', 'message': 'Spotify token is missing or expired. Please reconnect Spotify.'}), 400
    return jsonify(data), 200


# =============================================================================
# Avatar Management API
# =============================================================================

@app.route('/api/users/<user_id>/avatars', methods=['GET'])
@require_auth
def get_user_avatars(user_id: str):
    """List all avatars for a user."""
    if user_id != g.user_id:
        return jsonify({'error': 'Forbidden'}), 403
    
    limit = request.args.get('limit', 50, type=int)
    if limit < 1 or limit > 100:
        return jsonify({'error': 'Limit must be between 1 and 100'}), 400
    
    avatars = auth_manager.get_avatars(g.user_id, limit=limit)
    return jsonify({'avatars': avatars}), 200


@app.route('/api/users/<user_id>/avatars', methods=['POST'])
@require_auth
def upload_user_avatar(user_id: str):
    """Upload a new avatar for a user."""
    if user_id != g.user_id:
        return jsonify({'error': 'Forbidden'}), 403
    
    if 'file' not in request.files:
        return jsonify({'error': 'No file provided'}), 400
    
    file = request.files['file']
    filename = (file.filename or '').strip()
    if not file or not filename:
        return jsonify({'error': 'No file provided'}), 400
    
    # Read file content
    try:
        raw = file.read()
        if not raw:
            return jsonify({'error': 'Empty file'}), 400
    except Exception as e:
        server_logger.warning(f"Avatar upload failed to read: {e}")
        return jsonify({'error': 'Invalid image data'}), 400
    
    # Validate file
    is_valid, error_msg = validate_avatar_file(filename, len(raw))
    if not is_valid:
        return jsonify({'error': error_msg}), 400
    
    # Create user directory
    user_dir = ASSETS_DIR / 'images' / 'users' / str(g.user_id) / 'avatars'
    try:
        user_dir.mkdir(parents=True, exist_ok=True)
    except Exception as e:
        server_logger.error(f"Failed to create avatar directory {user_dir}: {e}")
        return jsonify({'error': 'Could not create storage directory'}), 500
    
    # Save file
    safe_filename = sanitize_avatar_filename(filename)
    out_path = user_dir / safe_filename
    try:
        out_path.write_bytes(raw)
    except Exception as e:
        server_logger.error(f"Failed to save avatar image: {e}")
        return jsonify({'error': 'Could not save avatar'}), 500
    
    # Generate public URL
    public_url = f"{Config.ASSETS_BASE_URL}/images/users/{g.user_id}/avatars/{safe_filename}"
    
    # Get MIME type
    mime_type = get_mime_type(filename)
    
    # Always mark new uploads as selected
    is_selected = True
    
    # Create avatar record
    try:
        avatar = auth_manager.create_avatar(
            user_id=g.user_id,
            url=public_url,
            source='upload',
            is_selected=is_selected,
            file_size=len(raw),
            mime_type=mime_type,
        )
        return jsonify({'avatar': avatar}), 201
    except Exception as e:
        server_logger.error(f"Failed to create avatar record: {e}")
        return jsonify({'error': 'Could not save avatar metadata'}), 500


@app.route('/api/users/<user_id>/avatars/<avatar_id>', methods=['PATCH'])
@require_auth
def update_user_avatar(user_id: str, avatar_id: str):
    """Update avatar properties (e.g., set as selected)."""
    if user_id != g.user_id:
        return jsonify({'error': 'Forbidden'}), 403
    
    data = request.get_json() or {}
    if not isinstance(data, dict):
        return jsonify({'error': 'Invalid payload'}), 400
    
    # Only support updating is_selected for now
    if 'is_selected' in data and data['is_selected']:
        success = auth_manager.update_avatar_selection(g.user_id, avatar_id)
        if not success:
            return jsonify({'error': 'Avatar not found'}), 404
        
        avatar = auth_manager.get_avatar_by_id(g.user_id, avatar_id)
        return jsonify({'avatar': avatar}), 200
    
    return jsonify({'error': 'No valid updates provided'}), 400


@app.route('/api/users/<user_id>/avatars/<avatar_id>', methods=['DELETE'])
@require_auth
def delete_user_avatar(user_id: str, avatar_id: str):
    """Delete an avatar."""
    if user_id != g.user_id:
        return jsonify({'error': 'Forbidden'}), 403
    
    # Get avatar to check source and get URL for file deletion
    avatar = auth_manager.get_avatar_by_id(g.user_id, avatar_id)
    if not avatar:
        return jsonify({'error': 'Avatar not found'}), 404
    
    if avatar.get('source') == 'provider':
        return jsonify({'error': 'Cannot delete provider avatars'}), 400
    
    avatar_url = avatar.get('url')
    
    # Delete from database
    success = auth_manager.delete_avatar(g.user_id, avatar_id)
    if not success:
        return jsonify({'error': 'Failed to delete avatar'}), 500
    
    # Try to delete file from disk (best effort)
    if avatar_url:
        try:
            # Extract filename from URL
            url_path = avatar_url.replace(Config.ASSETS_BASE_URL, '')
            file_path = ASSETS_DIR / url_path.lstrip('/')
            if file_path.exists():
                file_path.unlink()
        except Exception as e:
            server_logger.warning(f"Failed to delete avatar file: {e}")
    
    return jsonify({'message': 'Avatar deleted successfully'}), 200


# =============================================================================
# Miscellaneous API
# =============================================================================

@app.route('/assets/<path:filename>')
def serve_assets(filename: str):
    target = ASSETS_DIR / filename
    if not target.exists():
        return jsonify({'error': 'Not found'}), 404
    return send_from_directory(ASSETS_DIR, filename)

if __name__ == '__main__':
    app.run(host=Config.HOST, port=Config.PORT, debug=Config.DEBUG)
