#!/bin/bash
# Start the production server

cd "$(dirname "$0")"

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

# Start the server
echo ""
echo "Starting Spotify Now Playing Server..."
echo ""
python app.py
