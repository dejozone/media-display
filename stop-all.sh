#!/bin/bash
# Stop all media-display services

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get project root
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Load environment variable from server/.env to determine config file
ENV="dev"  # Default
if [ -f "$PROJECT_ROOT/server/.env" ]; then
    source "$PROJECT_ROOT/server/.env"
fi

# Read ports from JSON configuration files
CONFIG_FILE="${ENV}.json"

# Read server port from server/conf/{env}.json
if [ -f "$PROJECT_ROOT/server/conf/$CONFIG_FILE" ]; then
    SERVER_PORT=$(python3 -c "import json; print(json.load(open('$PROJECT_ROOT/server/conf/$CONFIG_FILE'))['websocket']['serverPort'])" 2>/dev/null || echo "5001")
else
    SERVER_PORT=5001
fi

# Read webapp port from webapp/conf/{env}.json
if [ -f "$PROJECT_ROOT/webapp/conf/$CONFIG_FILE" ]; then
    WEBAPP_PORT=$(python3 -c "import json; print(json.load(open('$PROJECT_ROOT/webapp/conf/$CONFIG_FILE'))['server']['port'])" 2>/dev/null || echo "8080")
else
    WEBAPP_PORT=8080
fi

echo -e "${YELLOW}Stopping Media Display services...${NC}"
echo ""

# Function to kill process on port
kill_on_port() {
    local port=$1
    local name=$2
    
    if lsof -ti :$port &>/dev/null; then
        lsof -ti :$port | xargs kill -9 2>/dev/null || true
        echo -e "${GREEN}✓ $name stopped (port $port)${NC}"
    else
        echo -e "${YELLOW}• $name not running (port $port)${NC}"
    fi
}

# Stop services
kill_on_port $SERVER_PORT "Spotify Server"
kill_on_port $WEBAPP_PORT "Web Application"

echo ""
echo -e "${GREEN}✓ All services stopped${NC}"
