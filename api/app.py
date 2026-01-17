#!/usr/bin/env python3
"""
Flask API for OAuth authentication and JWT management
"""
from flask import Flask, request, jsonify, g
from functools import wraps
import secrets
from flask_cors import CORS
from lib.auth.auth_manager import AuthManager
from config import Config
from lib.utils.logger import auth_logger, server_logger

app = Flask(__name__)
CORS(app, origins=Config.CORS_ORIGINS)
auth_manager = AuthManager()


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

@app.route('/api/auth/google/url')
def google_auth_url():
    state = secrets.token_urlsafe(16)
    url = auth_manager.google_client.get_authorization_url(state)
    return jsonify({'url': url, 'state': state})

@app.route('/api/auth/spotify/url')
def spotify_auth_url():
    state = secrets.token_urlsafe(16)
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
    token = auth_manager.login_with_spotify(code)
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
        token = auth_manager.login_with_spotify(code)
    else:
        return jsonify({'error': 'Unsupported provider'}), 400

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
def user_me():
    token = request.headers.get('Authorization')
    if not token or not token.startswith('Bearer '):
        return jsonify({'error': 'Missing or invalid Authorization header'}), 401
    jwt_token = token.split(' ', 1)[1]
    payload = auth_manager.validate_jwt(jwt_token)
    if not payload:
        return jsonify({'error': 'Invalid or expired JWT'}), 401
    return jsonify({'user': {
        'id': payload['sub'],
        'email': payload.get('email'),
        'name': payload.get('name'),
        'provider': payload.get('provider')
    }})


@app.route('/api/spotify/now-playing', methods=['GET'])
@require_auth
def spotify_now_playing():
    server_logger.info(f"/api/spotify/now-playing requested by user_id={g.user_id}")
    data = auth_manager.get_spotify_currently_playing(g.user_id)
    if data is None:
        server_logger.warning("Now-playing fetch failed: no tokens or refresh failure")
        return jsonify({'error': 'spotify_not_connected_or_token_invalid', 'code': 'ERR_SPOTIFY_4001', 'message': 'Spotify token is missing or expired. Please reconnect Spotify.'}), 400
    return jsonify(data), 200

if __name__ == '__main__':
    app.run(host=Config.HOST, port=Config.PORT, debug=Config.DEBUG)
