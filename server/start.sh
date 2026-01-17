#!/usr/bin/env bash
set -euo pipefail

# Change to server directory
cd "$(dirname "$0")"

# Create venv if missing
if [ ! -d ".venv" ]; then
  echo "📦 Creating virtual environment..."
  python3 -m venv .venv
fi

# Activate venv
source .venv/bin/activate

# Install dependencies
# pip install -q --upgrade pip
# pip install -q -r requirements.txt

# Default environment
export ENV="${ENV:-dev}"

# Run the app
python app.py
