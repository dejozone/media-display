#!/usr/bin/env python3
"""
Flask API for OAuth authentication and JWT management
"""
from flask import Flask, request, jsonify
from flask_cors import CORS
from lib.auth.auth_manager import AuthManager
from config import Config

app = Flask(__name__)
CORS(app, origins=Config.CORS_ORIGINS)
auth_manager = AuthManager()

@app.route('/auth/google/callback')
def google_callback():
    code = request.args.get('code')
    if not code:
        return jsonify({'error': 'Missing code'}), 400
    token = auth_manager.login_with_google(code)
    if not token:
        return jsonify({'error': 'Google OAuth failed'}), 401
    return jsonify({'jwt': token})

@app.route('/auth/spotify/callback')
def spotify_callback():
    code = request.args.get('code')
    if not code:
        return jsonify({'error': 'Missing code'}), 400
    token = auth_manager.login_with_spotify(code)
    if not token:
        return jsonify({'error': 'Spotify OAuth failed'}), 401
    return jsonify({'jwt': token})

@app.route('/auth/validate', methods=['POST'])
def validate_jwt():
    data = request.get_json()
    token = data.get('jwt') if data else None
    if not token:
        return jsonify({'error': 'Missing JWT'}), 400
    payload = auth_manager.validate_jwt(token)
    if not payload:
        return jsonify({'error': 'Invalid or expired JWT'}), 401
    return jsonify({'valid': True, 'payload': payload})

@app.route('/user/me')
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

if __name__ == '__main__':
    app.run(host=Config.HOST, port=Config.PORT, debug=Config.DEBUG)
