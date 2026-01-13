#!/bin/bash
# Start the production server
# Compatible with systemd service management

set -e  # Exit on error

# Get the absolute path to the script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$SCRIPT_DIR"

# Check for --gunicorn flag
USE_GUNICORN=false
if [ "$1" = "--gunicorn" ]; then
    USE_GUNICORN=true
fi

# Load environment variables from server/.env
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
    echo "✓ Environment variables loaded from $SCRIPT_DIR/.env"
else
    echo "⚠️  Warning: .env file not found at $SCRIPT_DIR/.env"
fi

# Activate virtual environment if it exists
if [ -d "$PROJECT_ROOT/.venv" ]; then
    source "$PROJECT_ROOT/.venv/bin/activate"
    echo "✓ Virtual environment activated: $PROJECT_ROOT/.venv"
else
    echo "⚠️  Warning: Virtual environment not found at $PROJECT_ROOT/.venv"
fi

# Verify Python is available
if ! command -v python &> /dev/null; then
    echo "✗ Error: Python not found in PATH"
    exit 1
fi

# Install dependencies if needed
if ! python -c "import flask_socketio" 2>/dev/null; then
    echo "Installing dependencies from requirements.txt..."
    pip install -r requirements.txt || {
        echo "✗ Error: Failed to install dependencies"
        exit 1
    }
fi

# Get server configuration from JSON config file
ENV=${ENV:-dev}
CONFIG_FILE="$SCRIPT_DIR/conf/${ENV}.json"

if [ -f "$CONFIG_FILE" ]; then
    PORT=$(python -c "import json; print(json.load(open('$CONFIG_FILE'))['websocket']['serverPort'])" 2>/dev/null || echo "5001")
    echo "✓ Configuration loaded from $CONFIG_FILE"
else
    PORT=5001
    echo "⚠️  Warning: Config file not found at $CONFIG_FILE, using default port $PORT"
fi

HOST=${SERVER_HOST:-0.0.0.0}

# Start the server
echo ""
if [ "$USE_GUNICORN" = true ]; then
    echo "Starting Spotify Now Playing Server with Gunicorn..."
    echo "Server: http://${HOST}:${PORT}"
    echo "Working directory: $SCRIPT_DIR"
    echo ""
    exec gunicorn -c gunicorn_config.py --bind ${HOST}:${PORT} app:app
else
    echo "Starting Spotify Now Playing Server (Development Mode)..."
    echo "Working directory: $SCRIPT_DIR"
    echo ""
    exec python app.py
fi
