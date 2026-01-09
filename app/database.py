#!/usr/bin/env python3
"""
Database module for Claude Notify PWA.
Handles push subscriptions, notifications, and settings.
"""

import os
import sqlite3
from typing import List, Optional
from contextlib import contextmanager

DB_PATH = os.environ.get('DB_PATH', '/app/data/claude_notify.db')


class Database:
    def __init__(self, db_path: str = None):
        self.db_path = db_path or DB_PATH
        os.makedirs(os.path.dirname(self.db_path), exist_ok=True)
        self._init_db()

    @contextmanager
    def _get_connection(self):
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        try:
            yield conn
        finally:
            conn.close()

    def _init_db(self):
        with self._get_connection() as conn:
            cursor = conn.cursor()

            cursor.execute("""
                CREATE TABLE IF NOT EXISTS push_subscriptions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    endpoint TEXT UNIQUE NOT NULL,
                    p256dh TEXT NOT NULL,
                    auth TEXT NOT NULL,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    last_used TEXT
                )
            """)

            cursor.execute("""
                CREATE TABLE IF NOT EXISTS claude_notifications (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    timestamp TEXT DEFAULT CURRENT_TIMESTAMP,
                    notification_type TEXT NOT NULL,
                    title TEXT NOT NULL,
                    body TEXT,
                    project_path TEXT,
                    status TEXT DEFAULT 'pending'
                )
            """)

            cursor.execute("""
                CREATE TABLE IF NOT EXISTS settings (
                    key TEXT PRIMARY KEY,
                    value TEXT
                )
            """)

            conn.commit()

    def save_push_subscription(self, subscription: dict) -> bool:
        endpoint = subscription.get('endpoint')
        keys = subscription.get('keys', {})
        p256dh = keys.get('p256dh')
        auth = keys.get('auth')

        if not all([endpoint, p256dh, auth]):
            raise ValueError("Invalid subscription: missing required fields")

        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                INSERT INTO push_subscriptions (endpoint, p256dh, auth)
                VALUES (?, ?, ?)
                ON CONFLICT(endpoint) DO UPDATE SET
                    p256dh = excluded.p256dh,
                    auth = excluded.auth,
                    last_used = CURRENT_TIMESTAMP
            """, (endpoint, p256dh, auth))
            conn.commit()
            return True

    def remove_push_subscription(self, endpoint: str) -> bool:
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("DELETE FROM push_subscriptions WHERE endpoint = ?", (endpoint,))
            conn.commit()
            return cursor.rowcount > 0

    def get_all_push_subscriptions(self) -> List[dict]:
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT endpoint, p256dh, auth FROM push_subscriptions")
            return [dict(row) for row in cursor.fetchall()]

    def update_push_subscription_last_used(self, endpoint: str):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                UPDATE push_subscriptions SET last_used = CURRENT_TIMESTAMP WHERE endpoint = ?
            """, (endpoint,))
            conn.commit()

    def get_subscription_count(self) -> int:
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT COUNT(*) FROM push_subscriptions")
            return cursor.fetchone()[0]

    def save_claude_notification(self, notification_type: str, title: str,
                                  body: str = None, project_path: str = None) -> int:
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                INSERT INTO claude_notifications
                (notification_type, title, body, project_path, status)
                VALUES (?, ?, ?, ?, 'pending')
            """, (notification_type, title, body, project_path))
            conn.commit()
            return cursor.lastrowid

    def get_claude_notification_history(self, limit: int = 50) -> List[dict]:
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT * FROM claude_notifications
                ORDER BY timestamp DESC
                LIMIT ?
            """, (limit,))
            return [dict(row) for row in cursor.fetchall()]

    def update_claude_notification_status(self, notification_id: int, status: str):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                UPDATE claude_notifications SET status = ? WHERE id = ?
            """, (status, notification_id))
            conn.commit()

    def get_claude_notification(self, notification_id: int) -> Optional[dict]:
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT * FROM claude_notifications WHERE id = ?", (notification_id,))
            row = cursor.fetchone()
            return dict(row) if row else None

    def get_setting(self, key: str) -> Optional[str]:
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT value FROM settings WHERE key = ?", (key,))
            row = cursor.fetchone()
            return row['value'] if row else None

    def set_setting(self, key: str, value: str):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                INSERT INTO settings (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, (key, value))
            conn.commit()

    def is_setup_complete(self) -> bool:
        return self.get_setting('setup_complete') == 'true'

    def mark_setup_complete(self):
        self.set_setting('setup_complete', 'true')
