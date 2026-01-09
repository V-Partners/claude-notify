#!/bin/bash
# Claude Notify - Start Script
# Auto-detects available port and starts the container

set -e

# Default port range to check
DEFAULT_PORT=5050
MAX_PORT=5099

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${CYAN}Claude Notify${NC}"
echo ""

# Check if a port is in use
is_port_in_use() {
    lsof -i :"$1" >/dev/null 2>&1
}

# Find available port
find_available_port() {
    for port in $(seq $DEFAULT_PORT $MAX_PORT); do
        if ! is_port_in_use $port; then
            echo $port
            return
        fi
    done
    echo ""
}

# Check if .env exists, if not copy example
if [ ! -f .env ]; then
    echo "Creating .env from .env.example..."
    cp .env.example .env
fi

# Check for PORT in environment or find one
if [ -n "$PORT" ]; then
    SELECTED_PORT=$PORT
else
    echo "Finding available port..."
    SELECTED_PORT=$(find_available_port)

    if [ -z "$SELECTED_PORT" ]; then
        echo -e "${YELLOW}No ports available in range $DEFAULT_PORT-$MAX_PORT${NC}"
        echo -n "Enter a port number: "
        read SELECTED_PORT
    fi
fi

# Confirm with user
echo ""
echo -e "Port: ${GREEN}$SELECTED_PORT${NC}"
echo -n "Start Claude Notify on this port? [Y/n] "
read -r response

if [[ "$response" =~ ^[Nn] ]]; then
    echo -n "Enter desired port: "
    read SELECTED_PORT
fi

# Export and start
export PORT=$SELECTED_PORT

echo ""
echo "Starting container on port $PORT..."
docker compose up -d

echo ""
echo -e "${GREEN}Claude Notify is running!${NC}"
echo ""
echo -e "Local:    http://localhost:$PORT"
echo -e "Setup:    http://localhost:$PORT/setup"
echo ""
echo "To stop: docker compose down"
