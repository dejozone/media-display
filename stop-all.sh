#!/bin/bash
# Stop all media-display services

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get project root
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Load environment variables
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
fi

# Configuration
SERVER_PORT=${WEBSOCKET_SERVER_PORT:-5001}
WEBAPP_PORT=${WEBAPP_PORT:-8081}

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
