#!/usr/bin/env python3
"""
Claude Notify PWA - Minimal Flask Application
Push notifications for Claude Code.
"""

import os
import io
import logging
from threading import Timer
from dotenv import load_dotenv

load_dotenv()

from flask import Flask, request, jsonify, render_template, send_from_directory, Response

from app.database import Database
from app.web_push import send_push_to_all, get_vapid_public_key, generate_vapid_keys

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__,
            template_folder='templates',
            static_folder='static')

delayed_notifications = {}


@app.route('/')
def index():
    """Main PWA page - shows setup wizard or notification UI."""
    db = Database()
    if not db.is_setup_complete():
        return render_template('setup.html')
    return render_template('index.html')


@app.route('/setup')
def setup():
    """Force show setup wizard."""
    return render_template('setup.html')


@app.route('/sw.js')
def service_worker():
    """Serve service worker from root scope."""
    return send_from_directory(app.static_folder, 'sw.js',
                               mimetype='application/javascript')


@app.route('/manifest.json')
def manifest():
    """Serve PWA manifest from root."""
    return send_from_directory(app.static_folder, 'manifest.json',
                               mimetype='application/manifest+json')


@app.route('/api/vapid-public-key')
def vapid_public_key():
    """Get the VAPID public key for push subscriptions."""
    public_key = get_vapid_public_key()
    if not public_key:
        return jsonify({'error': 'VAPID keys not configured'}), 500
    return jsonify({'publicKey': public_key})


@app.route('/api/push/subscribe', methods=['POST'])
def push_subscribe():
    """Save a push notification subscription."""
    data = request.get_json()
    if not data:
        return jsonify({'error': 'No subscription data'}), 400

    db = Database()
    try:
        db.save_push_subscription(data)
        return jsonify({'success': True})
    except ValueError as e:
        return jsonify({'error': str(e)}), 400
    except Exception as e:
        logger.error(f"Failed to save subscription: {e}")
        return jsonify({'error': 'Failed to save subscription'}), 500


@app.route('/api/push/unsubscribe', methods=['POST'])
def push_unsubscribe():
    """Remove a push subscription."""
    data = request.get_json()
    if not data or not data.get('endpoint'):
        return jsonify({'error': 'No endpoint provided'}), 400

    db = Database()
    removed = db.remove_push_subscription(data['endpoint'])
    return jsonify({'success': removed})


@app.route('/api/push/test', methods=['POST'])
def push_test():
    """Send a test push notification."""
    try:
        result = send_push_to_all(
            title="Test Notification",
            body="Claude Notify is working!",
            url="/",
            tag="test"
        )
        return jsonify(result)
    except Exception as e:
        logger.error(f"Failed to send test push: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/api/claude/notify', methods=['POST'])
def claude_notify():
    """Send an immediate push notification (for task completions)."""
    data = request.get_json()
    if not data:
        return jsonify({'error': 'No data provided'}), 400

    title = data.get('title', 'Claude Code')
    body = data.get('body', '')
    notification_type = data.get('notification_type', 'complete')
    project_path = data.get('project_path')

    db = Database()
    try:
        notification_id = db.save_claude_notification(
            notification_type=notification_type,
            title=title,
            body=body,
            project_path=project_path
        )

        result = send_push_to_all(
            title=title,
            body=body,
            url='/',
            tag=f'claude-{notification_type}'
        )

        db.update_claude_notification_status(notification_id, 'delivered')

        return jsonify({
            'success': True,
            'id': notification_id,
            'sent': result['sent'],
            'failed': result['failed']
        })
    except Exception as e:
        logger.error(f"Failed to send Claude notification: {e}")
        return jsonify({'error': str(e)}), 500


def deliver_delayed_notification(notification_id: int):
    """Deliver a delayed notification after timeout."""
    db = Database()
    notification = db.get_claude_notification(notification_id)

    if notification and notification['status'] == 'pending':
        result = send_push_to_all(
            title=notification['title'],
            body=notification['body'] or 'Claude Code is waiting for your input',
            url='/',
            tag=f"claude-waiting-{notification_id}",
            require_interaction=True
        )
        db.update_claude_notification_status(notification_id, 'delivered')
        logger.info(f"Delivered delayed notification {notification_id}: {result}")

    if notification_id in delayed_notifications:
        del delayed_notifications[notification_id]


@app.route('/api/claude/waiting', methods=['POST'])
def claude_waiting():
    """Start a delayed notification for when Claude is waiting."""
    data = request.get_json()
    if not data:
        return jsonify({'error': 'No data provided'}), 400

    title = data.get('title', 'Claude is waiting')
    body = data.get('body', 'Claude Code is waiting for your input')
    project_path = data.get('project_path')
    delay_seconds = data.get('delay', 120)

    db = Database()
    try:
        notification_id = db.save_claude_notification(
            notification_type='waiting',
            title=title,
            body=body,
            project_path=project_path
        )

        timer = Timer(delay_seconds, deliver_delayed_notification, [notification_id])
        timer.start()
        delayed_notifications[notification_id] = timer

        return jsonify({
            'success': True,
            'id': notification_id,
            'delay': delay_seconds,
            'message': f'Notification scheduled in {delay_seconds}s'
        })
    except Exception as e:
        logger.error(f"Failed to schedule waiting notification: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/api/claude/cancel/<int:notification_id>', methods=['POST'])
def claude_cancel(notification_id: int):
    """Cancel a pending delayed notification."""
    if notification_id in delayed_notifications:
        delayed_notifications[notification_id].cancel()
        del delayed_notifications[notification_id]

        db = Database()
        db.update_claude_notification_status(notification_id, 'cancelled')

        return jsonify({'success': True, 'cancelled': notification_id})

    return jsonify({'success': False, 'error': 'Notification not found or already delivered'}), 404


@app.route('/api/claude/history')
def claude_history():
    """Get Claude notification history."""
    limit = request.args.get('limit', 50, type=int)
    db = Database()
    notifications = db.get_claude_notification_history(limit)
    return jsonify(notifications)


@app.route('/api/setup/status')
def setup_status():
    """Check if setup is complete."""
    db = Database()
    vapid_key = get_vapid_public_key()
    return jsonify({
        'setup_complete': db.is_setup_complete(),
        'vapid_configured': bool(vapid_key),
        'subscription_count': db.get_subscription_count()
    })


@app.route('/api/setup/complete', methods=['POST'])
def setup_complete():
    """Mark setup as complete."""
    db = Database()
    db.mark_setup_complete()
    return jsonify({'success': True})


@app.route('/api/setup/generate-vapid', methods=['POST'])
def setup_generate_vapid():
    """Generate VAPID keys and save to .env file."""
    try:
        keys = generate_vapid_keys()
        logger.info(f"Generated VAPID keys, public key: {keys['public_key'][:20]}...")

        env_path = os.path.join(os.path.dirname(os.path.dirname(__file__)), '.env')
        logger.info(f"Writing VAPID keys to: {env_path}")

        existing_lines = []
        if os.path.exists(env_path):
            with open(env_path, 'r') as f:
                existing_lines = [
                    line for line in f.readlines()
                    if not line.startswith('VAPID_PRIVATE_KEY=')
                    and not line.startswith('VAPID_PUBLIC_KEY=')
                ]

        with open(env_path, 'w') as f:
            f.writelines(existing_lines)
            f.write(f"\nVAPID_PRIVATE_KEY={keys['private_key']}\n")
            f.write(f"VAPID_PUBLIC_KEY={keys['public_key']}\n")

        os.environ['VAPID_PRIVATE_KEY'] = keys['private_key']
        os.environ['VAPID_PUBLIC_KEY'] = keys['public_key']

        return jsonify({
            'success': True,
            'public_key': keys['public_key']
        })
    except Exception as e:
        logger.error(f"Failed to generate VAPID keys: {e}")
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500


@app.route('/api/qrcode')
def generate_qrcode():
    """Generate QR code for the current URL."""
    import qrcode

    url = request.args.get('url', request.host_url)

    qr = qrcode.QRCode(version=1, box_size=10, border=4)
    qr.add_data(url)
    qr.make(fit=True)

    img = qr.make_image(fill_color="white", back_color="#030508")

    buf = io.BytesIO()
    img.save(buf, format='PNG')
    buf.seek(0)

    return Response(buf.getvalue(), mimetype='image/png')


@app.route('/health')
def health():
    """Health check endpoint."""
    return jsonify({'status': 'healthy'})


if __name__ == '__main__':
    host = os.environ.get('HOST', '0.0.0.0')
    port = int(os.environ.get('PORT', 5000))

    logger.info(f"Starting Claude Notify on {host}:{port}")
    app.run(host=host, port=port, debug=False)
