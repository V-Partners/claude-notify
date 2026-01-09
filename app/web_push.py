#!/usr/bin/env python3
"""
Web Push Notification Module for Claude Notify PWA.
"""

import os
import json
import logging
from typing import Optional

from pywebpush import webpush, WebPushException
from py_vapid import Vapid

from app.database import Database

logger = logging.getLogger(__name__)

VAPID_PRIVATE_KEY = os.environ.get('VAPID_PRIVATE_KEY', '')
VAPID_PUBLIC_KEY = os.environ.get('VAPID_PUBLIC_KEY', '')
VAPID_EMAIL = os.environ.get('VAPID_EMAIL', 'mailto:admin@example.com')


def generate_vapid_keys() -> dict:
    """Generate a new VAPID key pair."""
    vapid = Vapid()
    vapid.generate_keys()
    return {
        'private_key': vapid.private_pem().decode('utf-8'),
        'public_key': vapid.public_key_urlsafe_base64()
    }


def get_vapid_public_key() -> str:
    """Get the VAPID public key, generating if needed."""
    global VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY

    if not VAPID_PUBLIC_KEY:
        env_path = os.path.join(os.path.dirname(os.path.dirname(__file__)), '.env')
        if os.path.exists(env_path):
            with open(env_path, 'r') as f:
                for line in f:
                    if line.startswith('VAPID_PUBLIC_KEY='):
                        VAPID_PUBLIC_KEY = line.split('=', 1)[1].strip()
                    elif line.startswith('VAPID_PRIVATE_KEY='):
                        VAPID_PRIVATE_KEY = line.split('=', 1)[1].strip()

    return VAPID_PUBLIC_KEY


def send_push_notification(
    subscription: dict,
    title: str,
    body: str,
    url: str = "/",
    tag: str = "claude-notification",
    require_interaction: bool = False,
    actions: list = None
) -> bool:
    """Send a push notification to a single subscription."""
    global VAPID_PRIVATE_KEY, VAPID_PUBLIC_KEY

    if not all([VAPID_PRIVATE_KEY, VAPID_PUBLIC_KEY]):
        logger.error("VAPID keys not configured")
        return False

    payload = json.dumps({
        "title": title,
        "body": body,
        "url": url,
        "tag": tag,
        "requireInteraction": require_interaction,
        "actions": actions or []
    })

    subscription_info = {
        "endpoint": subscription['endpoint'],
        "keys": {
            "p256dh": subscription['p256dh'],
            "auth": subscription['auth']
        }
    }

    try:
        webpush(
            subscription_info=subscription_info,
            data=payload,
            vapid_private_key=VAPID_PRIVATE_KEY,
            vapid_claims={"sub": VAPID_EMAIL}
        )
        logger.info(f"Push notification sent: {title}")
        return True
    except WebPushException as e:
        logger.error(f"Push notification failed: {e}")
        if e.response and e.response.status_code in [404, 410]:
            logger.info(f"Subscription expired, removing: {subscription['endpoint'][:50]}...")
            db = Database()
            db.remove_push_subscription(subscription['endpoint'])
        return False
    except Exception as e:
        logger.error(f"Unexpected error sending push: {e}")
        return False


def send_push_to_all(
    title: str,
    body: str,
    url: str = "/",
    tag: str = "claude-notification",
    require_interaction: bool = False,
    actions: list = None
) -> dict:
    """Send a push notification to all subscribed devices."""
    db = Database()
    subscriptions = db.get_all_push_subscriptions()

    results = {"sent": 0, "failed": 0}

    for sub in subscriptions:
        success = send_push_notification(
            subscription=sub,
            title=title,
            body=body,
            url=url,
            tag=tag,
            require_interaction=require_interaction,
            actions=actions
        )
        if success:
            results["sent"] += 1
            db.update_push_subscription_last_used(sub['endpoint'])
        else:
            results["failed"] += 1

    logger.info(f"Push notifications: {results['sent']} sent, {results['failed']} failed")
    return results
