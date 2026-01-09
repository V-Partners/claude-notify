#!/bin/bash
# Claude Notify - Complete Setup Script
# Sets up Docker, Tailscale Funnel, VAPID keys, and Claude hooks

set -e

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# Config
DEFAULT_PORT=5050
MAX_PORT=5099
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
echo -e "${CYAN}║       ${BOLD}Claude Notify Setup${NC}${CYAN}            ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
echo ""

# ============================================================
# Helper Functions
# ============================================================

check_command() {
    command -v "$1" >/dev/null 2>&1
}

is_port_in_use() {
    lsof -i :"$1" >/dev/null 2>&1 || ss -tuln | grep -q ":$1 "
}

find_available_port() {
    for port in $(seq $DEFAULT_PORT $MAX_PORT); do
        if ! is_port_in_use $port; then
            echo $port
            return
        fi
    done
    echo ""
}

print_step() {
    echo -e "${CYAN}→${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}!${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

# ============================================================
# Step 1: Check Dependencies
# ============================================================

print_step "Checking dependencies..."

MISSING_DEPS=()

if ! check_command docker; then
    MISSING_DEPS+=("docker")
fi

if ! check_command curl; then
    MISSING_DEPS+=("curl")
fi

if ! check_command jq; then
    MISSING_DEPS+=("jq")
fi

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    print_error "Missing dependencies: ${MISSING_DEPS[*]}"
    echo ""
    echo "Install them with:"
    echo "  sudo apt install ${MISSING_DEPS[*]}"
    exit 1
fi

# Check for qrencode (optional but recommended)
if ! check_command qrencode; then
    print_warning "qrencode not found - QR code will not be displayed"
    echo ""
    echo -n "Install qrencode now? [Y/n] "
    read -r response

    if [[ ! "$response" =~ ^[Nn] ]]; then
        echo "Installing qrencode..."
        sudo apt install -y qrencode
        HAS_QRENCODE=true
        print_success "qrencode installed"
    else
        HAS_QRENCODE=false
        print_warning "Skipping qrencode - you'll need to open the URL manually"
    fi
else
    HAS_QRENCODE=true
fi

print_success "Dependencies OK"

# ============================================================
# Step 2: Check/Install Tailscale
# ============================================================

print_step "Checking Tailscale..."

if ! check_command tailscale; then
    print_warning "Tailscale not installed"
    echo ""
    echo -n "Install Tailscale now? [Y/n] "
    read -r response

    if [[ ! "$response" =~ ^[Nn] ]]; then
        echo "Installing Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh
    else
        print_error "Tailscale is required for HTTPS (push notifications need HTTPS)"
        exit 1
    fi
fi

print_success "Tailscale installed"

# ============================================================
# Step 3: Authenticate Tailscale
# ============================================================

print_step "Checking Tailscale authentication..."

if ! tailscale status >/dev/null 2>&1; then
    print_warning "Tailscale not logged in"
    echo ""
    echo "Running 'tailscale up' to authenticate..."
    sudo tailscale up
fi

# Get machine name
TAILSCALE_STATUS=$(tailscale status --json 2>/dev/null || echo "{}")
TAILSCALE_HOSTNAME=$(echo "$TAILSCALE_STATUS" | jq -r '.Self.DNSName // empty' | sed 's/\.$//')

if [ -z "$TAILSCALE_HOSTNAME" ]; then
    print_error "Could not get Tailscale hostname"
    exit 1
fi

print_success "Tailscale authenticated as: $TAILSCALE_HOSTNAME"

# ============================================================
# Step 4: Find Available Port
# ============================================================

print_step "Finding available port..."

SELECTED_PORT=$(find_available_port)

if [ -z "$SELECTED_PORT" ]; then
    print_warning "No ports available in range $DEFAULT_PORT-$MAX_PORT"
    echo -n "Enter a port number: "
    read SELECTED_PORT
fi

echo -e "  Port: ${GREEN}$SELECTED_PORT${NC}"
echo -n "  Use this port? [Y/n] "
read -r response

if [[ "$response" =~ ^[Nn] ]]; then
    echo -n "  Enter desired port: "
    read SELECTED_PORT
fi

print_success "Using port $SELECTED_PORT"

# ============================================================
# Step 5: Create .env if needed
# ============================================================

cd "$SCRIPT_DIR"

if [ ! -f .env ]; then
    print_step "Creating .env file..."
    cp .env.example .env
    print_success ".env created"
fi

# ============================================================
# Step 6: Start Docker Container
# ============================================================

print_step "Starting Docker container..."

export PORT=$SELECTED_PORT
docker compose up -d --build 2>/dev/null || docker-compose up -d --build

# Wait for container to be healthy
echo "  Waiting for container to start..."
for i in {1..30}; do
    if curl -s "http://localhost:$SELECTED_PORT/health" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if ! curl -s "http://localhost:$SELECTED_PORT/health" >/dev/null 2>&1; then
    print_error "Container failed to start"
    docker compose logs
    exit 1
fi

print_success "Container running on port $SELECTED_PORT"

# ============================================================
# Step 6b: Install as systemd service
# ============================================================

print_step "Setting up systemd service..."

SERVICE_NAME="claude-notify"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

cat << EOF | sudo tee "$SERVICE_FILE" > /dev/null
[Unit]
Description=Claude Notify - Push notifications for Claude Code
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$SCRIPT_DIR
Environment=PORT=$SELECTED_PORT
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME" >/dev/null 2>&1

print_success "Systemd service installed (auto-starts on boot)"

# ============================================================
# Step 7: Generate VAPID Keys
# ============================================================

print_step "Checking VAPID keys..."

# Check if VAPID keys exist in .env
if grep -q "^VAPID_PUBLIC_KEY=.\+" .env 2>/dev/null; then
    print_success "VAPID keys already configured"
else
    print_step "Generating VAPID keys..."

    # Call the API to generate keys
    VAPID_RESPONSE=$(curl -s -X POST "http://localhost:$SELECTED_PORT/api/setup/generate-vapid")

    if echo "$VAPID_RESPONSE" | jq -e '.success == true' >/dev/null 2>&1; then
        print_success "VAPID keys generated"
    else
        print_error "Failed to generate VAPID keys"
        echo "  Response: $VAPID_RESPONSE"
        echo ""
        echo "  Container logs:"
        docker compose logs --tail=10
    fi
fi

# ============================================================
# Step 8: Configure Tailscale Funnel
# ============================================================

print_step "Configuring Tailscale Funnel..."

# Check if funnel is already configured for this port
FUNNEL_STATUS=$(tailscale funnel status 2>/dev/null || echo "")

if echo "$FUNNEL_STATUS" | grep -q ":$SELECTED_PORT"; then
    print_success "Tailscale Funnel already configured for port $SELECTED_PORT"
else
    echo "  Enabling Funnel for port $SELECTED_PORT..."
    sudo tailscale funnel --bg $SELECTED_PORT >/dev/null 2>&1
    print_success "Tailscale Funnel enabled"
fi

# Build the full HTTPS URL
HTTPS_URL="https://${TAILSCALE_HOSTNAME}"
if [ "$SELECTED_PORT" != "443" ]; then
    HTTPS_URL="${HTTPS_URL}:${SELECTED_PORT}"
fi

print_success "HTTPS URL: $HTTPS_URL"

# ============================================================
# Step 9: Configure Claude Hooks
# ============================================================

print_step "Configuring Claude Code hooks..."

NOTIFY_URL="${HTTPS_URL}/api/claude/notify"

echo ""
echo "  Claude Notify URL: $NOTIFY_URL"
echo ""
echo "  Which hooks do you want to enable?"
echo "    1) Stop hook (notify when Claude is waiting)"
echo "    2) None (I'll configure manually)"
echo ""
echo -n "  Choice [1]: "
read -r hook_choice

if [ "$hook_choice" != "2" ]; then
    # Ensure ~/.claude directory exists
    mkdir -p "$HOME/.claude"

    # Create or update settings.json
    if [ -f "$CLAUDE_SETTINGS" ]; then
        # Backup existing settings
        cp "$CLAUDE_SETTINGS" "${CLAUDE_SETTINGS}.backup"

        # Read existing settings and add/update hooks
        EXISTING=$(cat "$CLAUDE_SETTINGS")

        # Use jq to merge hooks
        UPDATED=$(echo "$EXISTING" | jq --arg url "$NOTIFY_URL" '
            .hooks = (.hooks // {}) |
            .hooks.stop = [
                {
                    "command": "curl -s -X POST \($url) -H \"Content-Type: application/json\" -d \"{\\\"title\\\": \\\"Claude Stopped\\\", \\\"body\\\": \\\"Waiting for your input\\\"}\" > /dev/null"
                }
            ]
        ')

        echo "$UPDATED" > "$CLAUDE_SETTINGS"
    else
        # Create new settings file
        cat > "$CLAUDE_SETTINGS" << EOF
{
  "hooks": {
    "stop": [
      {
        "command": "curl -s -X POST $NOTIFY_URL -H \"Content-Type: application/json\" -d \"{\\\"title\\\": \\\"Claude Stopped\\\", \\\"body\\\": \\\"Waiting for your input\\\"}\" > /dev/null"
      }
    ]
  }
}
EOF
    fi

    print_success "Claude hooks configured in $CLAUDE_SETTINGS"
else
    print_warning "Skipping Claude hook configuration"
    echo ""
    echo "  To manually configure, add to ~/.claude/settings.json:"
    echo ""
    echo "  {\"hooks\": {\"stop\": [{\"command\": \"curl -s -X POST $NOTIFY_URL ...\"}]}}"
fi

# ============================================================
# Step 10: Display QR Code
# ============================================================

echo ""
echo -e "${CYAN}══════════════════════════════════════${NC}"
echo -e "${BOLD}  Setup Complete!${NC}"
echo -e "${CYAN}══════════════════════════════════════${NC}"
echo ""

if [ "$HAS_QRENCODE" = true ]; then
    echo -e "${BOLD}Scan this QR code on your phone:${NC}"
    echo ""
    qrencode -t ANSIUTF8 "$HTTPS_URL"
    echo ""
fi

echo -e "${BOLD}Or visit:${NC} $HTTPS_URL"
echo ""
echo -e "${BOLD}Claude hook URL:${NC}"
echo "  $NOTIFY_URL"
echo ""
echo -e "${CYAN}──────────────────────────────────────${NC}"
echo ""
echo "Next steps:"
echo "  1. Scan QR code or open URL on your phone"
echo "  2. Install Tailscale app if prompted"
echo "  3. Add to Home Screen"
echo "  4. Enable notifications"
echo ""
echo "Service management:"
echo "  sudo systemctl stop claude-notify"
echo "  sudo systemctl start claude-notify"
echo "  sudo systemctl status claude-notify"
echo ""
echo "View logs: docker compose logs -f"
echo ""
