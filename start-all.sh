#!/bin/bash
# Unified startup script for media-display project
# Starts server, webapp, and opens browser when ready
# Compatible with systemd service management

set -e

# Detect if running under systemd
if [ -n "$INVOCATION_ID" ] || [ "$1" = "--systemd" ]; then
    SYSTEMD_MODE=true
    echo "Running in systemd mode"
else
    SYSTEMD_MODE=false
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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
# Always use Gunicorn for production-ready startup
USE_GUNICORN=true

# Store PIDs for cleanup
SERVER_PID=""
WEBAPP_PID=""

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Shutting down services...${NC}"
    
    if [ -n "$WEBAPP_PID" ]; then
        kill $WEBAPP_PID 2>/dev/null || true
        echo -e "${GREEN}✓ Webapp stopped${NC}"
    fi
    
    if [ -n "$SERVER_PID" ]; then
        kill $SERVER_PID 2>/dev/null || true
        echo -e "${GREEN}✓ Server stopped${NC}"
    fi
    
    exit 0
}

# Set up trap for cleanup
trap cleanup INT TERM

# Function to check if port is accepting connections
check_port() {
    local port=$1
    # Use nc (netcat) to check if port is open and accepting connections
    # -z: scan without sending data, -w1: 1 second timeout
    nc -z -w1 localhost $port &>/dev/null
}

# Function to wait for service to be ready
wait_for_service() {
    local port=$1
    local name=$2
    local pid=$3
    local log_file=$4
    local max_attempts=60
    local attempt=0
    
    echo -e "${BLUE}Waiting for $name to be ready on port $port...${NC}"
    
    # Give initial time for the process to start up
    sleep 5
    
    while [ $attempt -lt $max_attempts ]; do
        # Check if process is still running
        if ! kill -0 $pid 2>/dev/null; then
            echo -e "\n${RED}✗ $name process died unexpectedly${NC}"
            return 1
        fi
        
        # Check if port is accepting connections
        if check_port $port; then
            echo -e "${GREEN}✓ $name is ready!${NC}"
            return 0
        fi
        
        # Also check log file for success indicators
        if [ -f "$log_file" ]; then
            if grep -q "Starting server on" "$log_file" 2>/dev/null || \
               grep -q "Listening at:" "$log_file" 2>/dev/null; then
                # Give it a moment to actually bind to the port
                sleep 2
                if check_port $port; then
                    echo -e "${GREEN}✓ $name is ready!${NC}"
                    return 0
                fi
            fi
        fi
        
        sleep 1
        attempt=$((attempt + 1))
        if [ $((attempt % 5)) -eq 0 ]; then
            echo -n "."
        fi
    done
    
    echo -e "\n${RED}✗ $name failed to start within timeout${NC}"
    return 1
}

# Main startup sequence
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}  Media Display - Unified Startup${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""

# Clean up any existing processes on required ports
echo -e "${BLUE}Checking for existing processes...${NC}"
PORTS_TO_CHECK=("$SERVER_PORT" "$WEBAPP_PORT" "8888")  # Include OAuth callback port
FOUND_PROCESSES=false

for port in "${PORTS_TO_CHECK[@]}"; do
    if lsof -ti :$port &>/dev/null; then
        FOUND_PROCESSES=true
        echo -e "${YELLOW}⚠️  Found process on port $port, stopping...${NC}"
        lsof -ti :$port | xargs kill -9 2>/dev/null || true
    fi
done

# Also kill any Python processes from this project directory
pkill -9 -f "$PROJECT_ROOT" 2>/dev/null || true

if [ "$FOUND_PROCESSES" = true ]; then
    echo -e "${GREEN}✓ Cleaned up existing processes${NC}"
    sleep 3  # Give system more time to release ports
    
    # Verify ports are actually free
    for port in "${PORTS_TO_CHECK[@]}"; do
        attempt=0
        while lsof -ti :$port &>/dev/null && [ $attempt -lt 5 ]; do
            echo -e "${YELLOW}⚠️  Port $port still in use, waiting...${NC}"
            sleep 1
            attempt=$((attempt + 1))
        done
        
        if lsof -ti :$port &>/dev/null; then
            echo -e "${RED}✗ Failed to free port $port${NC}"
            echo -e "${YELLOW}Please run: lsof -ti :$port | xargs kill -9${NC}"
            exit 1
        fi
    done
    echo -e "${GREEN}✓ All ports are free${NC}"
else
    echo -e "${GREEN}✓ No existing processes found${NC}"
fi
echo ""

# Step 1: Start the server
echo -e "${YELLOW}[1/3] Starting Spotify Server...${NC}"
echo -e "${BLUE}→ This will open Spotify authentication in your browser${NC}"
echo ""

cd "$PROJECT_ROOT/server"
# Clear previous log and use unbuffered output for immediate log writing
> "$PROJECT_ROOT/server.log"
PYTHONUNBUFFERED=1 stdbuf -oL -eL ./start.sh --gunicorn >> "$PROJECT_ROOT/server.log" 2>&1 &
SERVER_PID=$!

# Wait for server to be ready
if ! wait_for_service $SERVER_PORT "Spotify Server" $SERVER_PID "$PROJECT_ROOT/server.log"; then
    echo -e "${RED}Check server.log for errors${NC}"
    cleanup
    exit 1
fi

echo -e "${GREEN}✓ Server started successfully (PID: $SERVER_PID)${NC}"
echo ""

# Check if Spotify authentication is already complete and valid
echo -e "${BLUE}Checking Spotify authentication status...${NC}"

SPOTIFY_CACHE="$PROJECT_ROOT/server/.spotify_cache"
AUTH_NEEDED=true

if [ -f "$SPOTIFY_CACHE" ]; then
    # Extract expires_at timestamp from the cache file
    EXPIRES_AT=$(python3 -c "
import json
import sys
try:
    with open('$SPOTIFY_CACHE', 'r') as f:
        cache = json.load(f)
        print(cache.get('expires_at', 0))
except:
    print(0)
" 2>/dev/null)
    
    # Get current timestamp
    CURRENT_TIME=$(date +%s)
    
    # Check if token is still valid (not expired)
    if [ "$EXPIRES_AT" -gt "$CURRENT_TIME" ]; then
        TIME_LEFT=$((EXPIRES_AT - CURRENT_TIME))
        MINUTES_LEFT=$((TIME_LEFT / 60))
        echo -e "${GREEN}✓ Spotify authentication valid (expires in ${MINUTES_LEFT} minutes)${NC}"
        AUTH_NEEDED=false
    else
        echo -e "${YELLOW}⚠️  Spotify token has expired, re-authentication needed${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  No cached Spotify credentials found${NC}"
fi

if [ "$AUTIn systemd mode, just log the requirement without prompting
        if [ "$SYSTEMD_MODE" = true ]; then
            # Extract authorization URL from log if available
            AUTH_URL=$(grep -o "https://accounts\.spotify\.com/authorize[^[:space:]]*" "$PROJECT_ROOT/server.log" 2>/dev/null | head -1)
            
            if [ -n "$AUTH_URL" ]; then
                DECODED_URL=$(python3 -c "import urllib.parse; print(urllib.parse.unquote('$AUTH_URL'))" 2>/dev/null || echo "$AUTH_URL")
                echo -e "${YELLOW}⚠️  Spotify authentication required${NC}"
                echo -e "${BLUE}Please authenticate using this link:${NC}"
                echo -e "${GREEN}$DECODED_URL${NC}"
            fi
            
            echo -e "${YELLOW}Note: Service will continue with limited functionality until authenticated${NC}"
        else
            # Extract authorization URL from log if available (simple approach)
            AUTH_URL=$(grep -o "https://accounts\.spotify\.com/authorize[^[:space:]]*" "$PROJECT_ROOT/server.log" 2>/dev/null | head -1)
            
            if [ -n "$AUTH_URL" ]; then
                # Decode URL for better readability
                DECODED_URL=$(python3 -c "import urllib.parse; print(urllib.parse.unquote('$AUTH_URL'))" 2>/dev/null || echo "$AUTH_URL")
                
                echo -e "${YELLOW}⚠️  Spotify authentication required${NC}"
                echo -e "${BLUE}If browser didn't open automatically, use this link:${NC}"
                echo -e "${GREEN}$DECODED_URL${NC}"
                echo ""
            else
                echo -e "${YELLOW}⚠️  Please complete Spotify authentication in the browser${NC}"
            fi
            
            echo -e "${BLUE}Press Enter when authentication is complete...${NC}"
            read -r
        fio -e "${YELLOW}⚠️  Spotify authentication required${NC}"
            echo -e "${BLUE}If browser didn't open automatically, use this link:${NC}"
            echo -e "${GREEN}$DECODED_URL${NC}"
            echo ""
        else
            echo -e "${YELLOW}⚠️  Please complete Spotify authentication in the browser${NC}"
        fi
        
        echo -e "${BLUE}Press Enter when authentication is complete...${NC}"
        read -r
    fi
fi

# Step 2: Start the webapp
echo ""
echo -e "${YELLOW}[2/3] Starting Web Application...${NC}"
echo ""

cd "$PROJECT_ROOT/webapp"
# Clear previous log and use unbuffered output for immediate log writing
> "$PROJECT_ROOT/webapp.log"
PYTHONUNBUFFERED=1 stdbuf -oL -eL ./start.sh --gunicorn >> "$PROJECT_ROOT/webapp.log" 2>&1 &
WEBAPP_PID=$!


# Only open browser in non-systemd mode
if [ "$SYSTEMD_MODE" = false ]; then
    echo -e "${BLUE}→ Opening: $WEBAPP_URL${NC}"
    
    if command -v open &> /dev/null; then
        open "$WEBAPP_URL"
    else
        echo -e "${YELLOW}⚠️  Please open $WEBAPP_URL manually${NC}"
    fi
else
    echo -e "${BLUE}→ Browser access: $WEBAPP_URL

echo -e "${GREEN}✓ Webapp started successfully (PID: $WEBAPP_PID)${NC}"
echo ""

# Step 3: Open browser
echo -e "${YELLOW}[3/3] Opening browser...${NC}"
sleep 2  # Brief delay to ensure webapp is fully ready

WEBAPP_URL="http://localhost:${WEBAPP_PORT}"
echo -e "${BLUE}→ Opening: $WEBAPP_URL${NC}"

if [ "$SYSTEMD_MODE" = false ]; then
    echo -e "${YELLOW}Press Ctrl+C to stop all services${NC}"
    echo ""
fiand -v open &> /dev/null; then
    open "$WEBAPP_URL"
else
    echo -e "${YELLOW}⚠️  Please open $WEBAPP_URL manually${NC}"
fi

# Success message
echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✓ All services started successfully!${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo -e "${BLUE}Services:${NC}"
echo -e "  • Spotify Server: http://localhost:${SERVER_PORT}"
echo -e "  • Web Application: http://localhost:${WEBAPP_PORT}"
echo ""
echo -e "${BLUE}Logs:${NC}"
echo -e "  • Server: $PROJECT_ROOT/server.log"
echo -e "  • Webapp: $PROJECT_ROOT/webapp.log"
echo ""
echo -e "${YELLOW}Press Ctrl+C to stop all services${NC}"
echo ""

# Keep script running
wait
