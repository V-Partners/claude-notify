# Claude Notify

Push notifications for Claude Code. Get notified on your phone when Claude needs your attention.

## Overview

Claude Notify sends push notifications to your phone when Claude Code stops and waits for input. No more checking back constantly - just wait for the buzz.

```
Claude Code stops → Hook triggers → Push notification → Phone buzzes
```

## Quick Start

```bash
git clone https://github.com/V-Partners/claude-notify.git
cd claude-notify
./setup.sh
```

The setup script handles everything automatically:

1. **Checks dependencies** - Docker, Tailscale, qrencode
2. **Starts the container** - Finds an available port
3. **Configures Tailscale Funnel** - HTTPS for push notifications
4. **Sets up Claude hooks** - Updates `~/.claude/settings.json`
5. **Shows QR code** - Scan with your phone to complete setup

## Requirements

- Docker
- Tailscale account (free)
- iPhone or Android phone

## How It Works

### Desktop Setup

Run `./setup.sh` and follow the prompts:

```
╔══════════════════════════════════════╗
║       Claude Notify Setup            ║
╚══════════════════════════════════════╝

✓ Docker running
✓ Tailscale authenticated
✓ Container started on port 5050
✓ VAPID keys generated
✓ Tailscale Funnel enabled
✓ Claude hooks configured

Scan this QR code on your phone:

  █▀▀▀▀▀█ ▄▄▄▄▄ █▀▀▀▀▀█
  █ ███ █ █▄▄▄█ █ ███ █
  ...

Or visit: https://your-machine.tail12345.ts.net
```

### Phone Setup

1. **Scan the QR code** displayed in your terminal
2. **Install Tailscale** app if prompted (App Store / Play Store)
3. **Add to Home Screen** - Follow the on-screen instructions
4. **Enable notifications** - Tap the button and allow
5. **Send a test** - Verify it works

## API

Send notifications programmatically:

```bash
curl -X POST https://your-machine.ts.net/api/claude/notify \
  -H "Content-Type: application/json" \
  -d '{"title": "Task Complete", "body": "Build finished successfully"}'
```

Or use the included CLI:

```bash
./scripts/notify.py "Task Complete" "Build finished"
```

### Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/claude/notify` | POST | Send immediate notification |
| `/api/claude/waiting` | POST | Schedule delayed notification |
| `/api/claude/cancel/<id>` | POST | Cancel pending notification |
| `/api/claude/history` | GET | Get notification history |
| `/health` | GET | Health check |

### Notification Payload

```json
{
  "title": "Claude Code",
  "body": "Your task is complete",
  "notification_type": "complete",
  "project_path": "/path/to/project"
}
```

## Configuration

### Claude Hooks

The setup script automatically configures Claude Code hooks. To manually configure:

```json
// ~/.claude/settings.json
{
  "hooks": {
    "stop": [
      {
        "command": "curl -s -X POST https://your-machine.ts.net/api/claude/notify -H 'Content-Type: application/json' -d '{\"title\": \"Claude Stopped\", \"body\": \"Waiting for input\"}'"
      }
    ]
  }
}
```

### Environment Variables

```bash
# .env
VAPID_PRIVATE_KEY=...  # Auto-generated
VAPID_PUBLIC_KEY=...   # Auto-generated
VAPID_EMAIL=mailto:your-email@example.com
```

## Troubleshooting

### Notifications not working

1. Ensure you're accessing via HTTPS (Tailscale Funnel URL)
2. Check browser notification permissions
3. Make sure Tailscale is connected on your phone
4. Try the test button in the app

### Service management

```bash
# Check status
sudo systemctl status claude-notify

# Restart
sudo systemctl restart claude-notify

# Stop
sudo systemctl stop claude-notify

# View logs
docker compose logs -f
```

### Tailscale Funnel

```bash
# Check funnel status
tailscale funnel status

# Re-enable funnel
tailscale funnel 5050
```

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Claude Code    │────▶│  Claude Notify  │────▶│   Your Phone    │
│  (hook fires)   │     │  (Flask + VAPID)│     │  (PWA + Push)   │
└─────────────────┘     └─────────────────┘     └─────────────────┘
                              │
                              ▼
                        ┌───────────┐
                        │ Tailscale │
                        │  Funnel   │
                        │  (HTTPS)  │
                        └───────────┘
```

- **Flask app** handles notification API
- **VAPID/Web Push** sends to browser push services
- **Tailscale Funnel** provides HTTPS (required for service workers)
- **PWA** receives and displays notifications

## License

MIT
