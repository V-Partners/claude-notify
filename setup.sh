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

# Detect OS
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
else
    OS="linux"
fi

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
    if [ "$OS" = "macos" ]; then
        lsof -i :"$1" >/dev/null 2>&1
    else
        lsof -i :"$1" >/dev/null 2>&1 || ss -tuln 2>/dev/null | grep -q ":$1 "
    fi
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
    if [ "$OS" = "macos" ]; then
        echo "  brew install ${MISSING_DEPS[*]}"
    else
        echo "  sudo apt install ${MISSING_DEPS[*]}"
    fi
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
        if [ "$OS" = "macos" ]; then
            brew install qrencode
        else
            sudo apt install -y qrencode
        fi
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
        if [ "$OS" = "macos" ]; then
            brew install --cask tailscale
            echo ""
            print_warning "Please open the Tailscale app from Applications to start it"
            echo -n "Press Enter once Tailscale is running..."
            read -r
        else
            curl -fsSL https://tailscale.com/install.sh | sh
        fi
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
# Step 6b: Install as system service (auto-start on boot)
# ============================================================

print_step "Setting up auto-start service..."

SERVICE_NAME="claude-notify"

if [ "$OS" = "macos" ]; then
    # macOS: Use launchd
    PLIST_FILE="$HOME/Library/LaunchAgents/com.claude-notify.plist"
    mkdir -p "$HOME/Library/LaunchAgents"

    cat << EOF > "$PLIST_FILE"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude-notify</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/docker</string>
        <string>compose</string>
        <string>up</string>
        <string>-d</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$SCRIPT_DIR</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PORT</key>
        <string>$SELECTED_PORT</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF

    launchctl unload "$PLIST_FILE" 2>/dev/null || true
    launchctl load "$PLIST_FILE"

    print_success "LaunchAgent installed (auto-starts on login)"
else
    # Linux: Use systemd
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
fi

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

# Function to enable funnel (returns 0 on success, 1 on failure)
enable_funnel() {
    # Reset any existing serve config first
    sudo tailscale serve reset 2>/dev/null || true

    # Try different syntaxes for different Tailscale versions
    if sudo tailscale serve --bg --funnel 443 http://localhost:$SELECTED_PORT 2>&1; then
        return 0
    elif sudo tailscale serve --funnel 443 http://localhost:$SELECTED_PORT 2>&1; then
        return 0
    elif sudo tailscale funnel 443 http://localhost:$SELECTED_PORT 2>&1; then
        return 0
    else
        return 1
    fi
}

# Check if funnel is already configured for this port
FUNNEL_STATUS=$(tailscale funnel status 2>/dev/null || echo "")

if echo "$FUNNEL_STATUS" | grep -q "localhost:$SELECTED_PORT"; then
    print_success "Tailscale Funnel already configured for port $SELECTED_PORT"
else
    echo "  Enabling Funnel for port $SELECTED_PORT..."

    # Disable exit on error for this section
    set +e
    FUNNEL_OUTPUT=$(enable_funnel 2>&1)
    FUNNEL_EXIT=$?
    set -e

    # Check if funnel is not enabled on the account
    if echo "$FUNNEL_OUTPUT" | grep -qi "funnel not available\|not enabled\|enable funnel\|ACL\|policy"; then
        echo ""
        print_warning "Tailscale Funnel is not enabled on your account"
        echo ""
        echo -e "  ${BOLD}To enable Funnel:${NC}"
        echo "  1. Open: https://login.tailscale.com/admin/acls"
        echo "  2. Add this to your ACL policy:"
        echo ""
        echo -e "     ${CYAN}\"nodeAttrs\": [{\"target\": [\"*\"], \"attr\": [\"funnel\"]}]${NC}"
        echo ""
        echo "  Or for the new admin console, go to DNS settings and enable Funnel."
        echo ""
        echo -n "  Press Enter after enabling Funnel in admin console..."
        read -r

        # Retry
        echo "  Retrying..."
        set +e
        FUNNEL_OUTPUT=$(enable_funnel 2>&1)
        FUNNEL_EXIT=$?
        set -e
    fi

    if [ $FUNNEL_EXIT -eq 0 ] || echo "$FUNNEL_OUTPUT" | grep -qi "available on the internet"; then
        print_success "Tailscale Funnel enabled"
    else
        print_warning "Funnel setup had issues (may still work)"
        echo "  $FUNNEL_OUTPUT"
    fi
fi

# Build the full HTTPS URL (Funnel always serves on 443 externally)
HTTPS_URL="https://${TAILSCALE_HOSTNAME}"

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
if [ "$OS" = "macos" ]; then
    echo "  launchctl stop com.claude-notify"
    echo "  launchctl start com.claude-notify"
    echo "  docker compose ps"
else
    echo "  sudo systemctl stop claude-notify"
    echo "  sudo systemctl start claude-notify"
    echo "  sudo systemctl status claude-notify"
fi
echo ""
echo "View logs: docker compose logs -f"
echo ""
