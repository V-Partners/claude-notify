#!/usr/bin/env python3
"""
CLI script for sending Claude notifications.
Use with Claude Code hooks or from command line.

Usage:
    ./notify.py "Title" "Body message"
    ./notify.py --waiting "Waiting for input" --delay 120

Environment:
    CLAUDE_NOTIFY_URL - Notification endpoint (default: http://localhost:5000/api/claude/notify)
"""

import os
import sys
import json
import argparse
import urllib.request
import urllib.error

DEFAULT_URL = os.environ.get('CLAUDE_NOTIFY_URL', 'http://localhost:5000/api/claude/notify')


def send_notification(url: str, title: str, body: str = None,
                      notification_type: str = 'complete', project_path: str = None,
                      delay: int = None) -> dict:
    """Send a notification to the Claude Notify server."""

    if notification_type == 'waiting':
        url = url.replace('/notify', '/waiting')

    payload = {
        'title': title,
        'body': body,
        'notification_type': notification_type,
        'project_path': project_path or os.getcwd()
    }

    if delay is not None:
        payload['delay'] = delay

    data = json.dumps(payload).encode('utf-8')

    req = urllib.request.Request(
        url,
        data=data,
        headers={'Content-Type': 'application/json'},
        method='POST'
    )

    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return json.loads(response.read().decode('utf-8'))
    except urllib.error.URLError as e:
        return {'error': str(e), 'success': False}
    except Exception as e:
        return {'error': str(e), 'success': False}


def main():
    parser = argparse.ArgumentParser(
        description='Send notifications to Claude Notify PWA',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    %(prog)s "Task Complete" "Build finished successfully"
    %(prog)s --waiting "Waiting for input" --delay 60
    %(prog)s --url https://myhost.ts.net/api/claude/notify "Hello" "World"
        """
    )

    parser.add_argument('title', nargs='?', default='Claude Code',
                        help='Notification title')
    parser.add_argument('body', nargs='?', default=None,
                        help='Notification body')
    parser.add_argument('--url', default=DEFAULT_URL,
                        help=f'Notification URL (default: {DEFAULT_URL})')
    parser.add_argument('--waiting', action='store_true',
                        help='Send as waiting notification (delayed)')
    parser.add_argument('--delay', type=int, default=120,
                        help='Delay in seconds for waiting notifications (default: 120)')
    parser.add_argument('--project', default=None,
                        help='Project path (default: current directory)')

    args = parser.parse_args()

    notification_type = 'waiting' if args.waiting else 'complete'

    result = send_notification(
        url=args.url,
        title=args.title,
        body=args.body,
        notification_type=notification_type,
        project_path=args.project,
        delay=args.delay if args.waiting else None
    )

    if result.get('success'):
        print(f"Notification sent (ID: {result.get('id')})")
        if result.get('sent') is not None:
            print(f"  Delivered to {result.get('sent')} device(s)")
    else:
        print(f"Failed: {result.get('error', 'Unknown error')}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
