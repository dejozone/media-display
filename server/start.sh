#!/bin/bash
# Start the production server

cd "$(dirname "$0")"

# Check for --gunicorn flag
USE_GUNICORN=false
if [ "$1" = "--gunicorn" ]; then
    USE_GUNICORN=true
fi

# Load environment variables
if [ -f ../.env ]; then
    set -a
    source ../.env
    set +a
    echo "✓ Environment variables loaded"
else
    echo "⚠️  Warning: .env file not found"
fi

# Activate virtual environment if it exists
if [ -d ../.venv ]; then
    source ../.venv/bin/activate
    echo "✓ Virtual environment activated"
fi

# Install dependencies if needed
if ! python -c "import flask_socketio" 2>/dev/null; then
    echo "Installing dependencies..."
    pip install -r requirements.txt
fi

# Get server configuration from environment or use defaults
HOST=${SERVER_HOST:-0.0.0.0}
PORT=${WEBSOCKET_SERVER_PORT:-5001}

# Start the server
echo ""
if [ "$USE_GUNICORN" = true ]; then
    echo "Starting Spotify Now Playing Server with Gunicorn..."
    echo "Server: http://${HOST}:${PORT}"
    echo ""
    gunicorn -c gunicorn_config.py app:app
else
    echo "Starting Spotify Now Playing Server (Development Mode)..."
    echo ""
    python app.py
fi
