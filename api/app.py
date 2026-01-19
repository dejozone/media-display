#!/usr/bin/env python3
"""
Flask API for OAuth authentication and JWT management
"""
from flask import Flask, request, jsonify, g, send_from_directory
from functools import wraps
import secrets
from flask_cors import CORS
import re
from pathlib import Path
from lib.auth.auth_manager import AuthManager
from config import Config
from lib.utils.logger import auth_logger, server_logger

app = Flask(__name__)
CORS(app, origins=Config.CORS_ORIGINS)
auth_manager = AuthManager()
email_re = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
ASSETS_DIR = Config.ASSETS_ROOT
ALLOWED_IMAGE_EXT = {'.jpg', '.jpeg', '.png', '.bmp', '.heic', '.heif'}
MAX_AVATAR_UPLOAD = 8 * 1024 * 1024  # 8MB


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


@app.route('/assets/<path:filename>')
def serve_assets(filename: str):
    target = ASSETS_DIR / filename
    if not target.exists():
        return jsonify({'error': 'Not found'}), 404
    return send_from_directory(ASSETS_DIR, filename)

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
    return jsonify({'url': url, 'state': state})

@app.route('/api/auth/google/callback')
def google_callback():
    code = request.args.get('code')
    if not code:
        return jsonify({'error': 'Missing code'}), 400
    token = auth_manager.login_with_google(code)
    if not token:
        return jsonify({'error': 'Google OAuth failed'}), 401
    return jsonify({'jwt': token})

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
        return jsonify({'error': 'This Spotify account is already linked to another user.', 'code': err}), 409
    if not token:
        return jsonify({'error': 'Spotify OAuth failed'}), 401
    return jsonify({'jwt': token})


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
        return jsonify({'error': 'This Spotify account is already linked to another user.', 'code': err}), 409
    if not token:
        return jsonify({'error': f'{provider.capitalize()} OAuth failed'}), 401
    return jsonify({'jwt': token})

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

@app.route('/api/user/me')
@require_auth
def user_me():
    user = auth_manager.get_user(g.user_id)
    if not user:
        return jsonify({'error': 'User not found'}), 404

    identities = auth_manager.get_identities(g.user_id) or []
    selected_identity = next((i for i in identities if i.get('is_selected')), identities[0] if identities else None)
    provider = selected_identity.get('provider') if selected_identity else None
    provider_avatars = {i.get('provider'): i.get('avatar_url') for i in identities if i.get('provider')}
    provider_avatar_list = [
        {
            'provider': i.get('provider'),
            'provider_id': i.get('provider_id'),
            'avatar_url': i.get('avatar_url'),
            'is_selected': i.get('is_selected'),
        }
        for i in identities if i.get('provider')
    ]
    avatar_url = next((i.get('avatar_url') for i in identities if i.get('is_selected') and i.get('avatar_url')), None)
    if not avatar_url:
        avatar_url = next((i.get('avatar_url') for i in identities if i.get('avatar_url')), None)
    spotify_connected = auth_manager.has_spotify_tokens(g.user_id)

    return jsonify({'user': {
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
    }})


@app.route('/api/settings', methods=['GET'])
@require_auth
def get_settings():
    settings = auth_manager.get_dashboard_settings(g.user_id) or {}
    return jsonify({'settings': settings})


@app.route('/api/settings', methods=['PUT', 'PATCH'])
@require_auth
def update_settings():
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


@app.route('/api/account', methods=['GET'])
@require_auth
def get_account():
    user = auth_manager.get_user(g.user_id)
    if not user:
        return jsonify({'error': 'User not found'}), 404
    identities = auth_manager.get_identities(g.user_id) or []
    provider_avatars = {i.get('provider'): i.get('avatar_url') for i in identities if i.get('provider')}
    provider_avatar_list = [
        {
            'provider': i.get('provider'),
            'provider_id': i.get('provider_id'),
            'avatar_url': i.get('avatar_url'),
            'is_selected': i.get('is_selected'),
        }
        for i in identities if i.get('provider')
    ]
    selected_identity = next((i for i in identities if i.get('is_selected')), identities[0] if identities else None)
    avatar_url = selected_identity.get('avatar_url') if selected_identity else None
    if not avatar_url:
        avatar_url = next((i.get('avatar_url') for i in identities if i.get('avatar_url')), None)
    provider = selected_identity.get('provider') if selected_identity else None
    spotify_connected = auth_manager.has_spotify_tokens(g.user_id)
    return jsonify({
        'user': {
            'id': user.get('id'),
            'email': user.get('email'),
            'username': user.get('username'),
            'display_name': user.get('display_name'),
            'avatar_url': avatar_url,
            'provider_avatars': provider_avatars,
            'provider_avatar_list': provider_avatar_list,
            'provider': provider,
            'provider_selected': provider,
            'spotifyConnected': spotify_connected,
            'name': user.get('display_name') or user.get('username') or user.get('email'),
        }
    })


@app.route('/api/account', methods=['PUT', 'PATCH'])
@require_auth
def update_account():
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
    provider_avatars = {i.get('provider'): i.get('avatar_url') for i in identities if i.get('provider')}
    provider_avatar_list = [
        {
            'provider': i.get('provider'),
            'provider_id': i.get('provider_id'),
            'avatar_url': i.get('avatar_url'),
            'is_selected': i.get('is_selected'),
        }
        for i in identities if i.get('provider')
    ]
    selected_identity = next((i for i in identities if i.get('is_selected')), identities[0] if identities else None)
    chosen_avatar = avatar_url or (selected_identity.get('avatar_url') if selected_identity else None)
    if not chosen_avatar:
        chosen_avatar = next((i.get('avatar_url') for i in identities if i.get('avatar_url')), None)
    selected_provider = selected_identity.get('provider') if selected_identity else None

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


@app.route('/api/account/avatar', methods=['POST'])
@require_auth
def upload_avatar():
    if 'file' not in request.files:
        return jsonify({'error': 'No file provided'}), 400

    file = request.files['file']
    filename = (file.filename or '').strip()
    if not file or not filename:
        return jsonify({'error': 'No file provided'}), 400

    ext = Path(filename).suffix.lower()
    if ext not in ALLOWED_IMAGE_EXT:
        return jsonify({'error': 'Unsupported file type. Use JPG, PNG, BMP, or HEIC/HEIF.'}), 400

    content_length = request.content_length or 0
    if content_length > MAX_AVATAR_UPLOAD:
        return jsonify({'error': 'File too large. Max 8MB.'}), 413

    try:
        raw = file.read()
        if not raw:
            return jsonify({'error': 'Empty file'}), 400
        if len(raw) > MAX_AVATAR_UPLOAD:
            return jsonify({'error': 'File too large. Max 8MB.'}), 413
    except Exception as e:
        server_logger.warning(f"Avatar upload failed to read: {e}")
        return jsonify({'error': 'Invalid image data'}), 400

    user_dir = ASSETS_DIR / 'images' / 'users' / str(g.user_id)
    try:
        user_dir.mkdir(parents=True, exist_ok=True)
    except Exception as e:
        server_logger.error(f"Failed to create avatar directory {user_dir}: {e}")
        return jsonify({'error': 'Could not create storage directory'}), 500

    out_path = user_dir / 'avatar.jpg'
    try:
        out_path.write_bytes(raw)
    except Exception as e:
        server_logger.error(f"Failed to save avatar image: {e}")
        return jsonify({'error': 'Could not save avatar'}), 500

    public_url = f"{Config.ASSETS_BASE_URL}/images/users/{g.user_id}/avatar.jpg"

    try:
        auth_manager.update_identity_avatar(g.user_id, public_url)
    except Exception as e:
        server_logger.warning(f"Failed to update identity avatar for user {g.user_id}: {e}")

    return jsonify({'avatar_url': public_url}), 200


@app.route('/api/spotify/now-playing', methods=['GET'])
@require_auth
def spotify_now_playing():
    server_logger.debug(f"/api/spotify/now-playing requested by user_id={g.user_id}")
    data = auth_manager.get_spotify_currently_playing(g.user_id)
    if data is None:
        server_logger.warning("Now-playing fetch failed: no tokens or refresh failure")
        return jsonify({'error': 'spotify_not_connected_or_token_invalid', 'code': 'ERR_SPOTIFY_4001', 'message': 'Spotify token is missing or expired. Please reconnect Spotify.'}), 400
    return jsonify(data), 200

if __name__ == '__main__':
    app.run(host=Config.HOST, port=Config.PORT, debug=Config.DEBUG)
