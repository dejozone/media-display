#!/bin/bash
# Load environment variables and run the test script

cd "$(dirname "$0")/.."
set -a
source .env
set +a
source .venv/bin/activate
python test/spotify_connect_test.py
