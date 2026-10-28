import hashlib
import hmac
import json
import re
import sqlite3
import tempfile
import unittest

from clients.flask_app.app import create_app


class BroadcastexAuthAppTest(unittest.TestCase):
    def setUp(self) -> None:
        self.app_key = "test-key"
        self.app_secret = "test-secret"
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.app = create_app(
            {
                "TESTING": True,
                "SECRET_KEY": "test-session-secret",
                "DATABASE": f"{self.tempdir.name}/users.sqlite3",
                "BROADCASTEX_APP_KEY": self.app_key,
                "BROADCASTEX_APP_SECRET": self.app_secret,
                "BROADCASTEX_WS_URL": "ws://localhost:4000",
            },
        )
        self.client = self.app.test_client()

    def authenticate(self) -> None:
        response = self.client.get("/register")
        csrf_token = re.search(rb'name="csrf_token" value="([^"]+)"', response.data)
        self.assertIsNotNone(csrf_token)
        response = self.client.post(
            "/register",
            data={
                "csrf_token": csrf_token.group(1).decode(),
                "username": "user_123",
                "password": "correct horse battery",
            },
        )
        self.assertEqual(response.status_code, 302)

    def test_serves_html_with_authenticated_user_and_client_script(self) -> None:
        self.authenticate()
        response = self.client.get("/")
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"user_id", response.data)
        script_response = self.client.get("/broadcastex.js")
        self.assertEqual(script_response.status_code, 200)
        script_response.close()

    def test_authorizes_private_room_by_prefix(self) -> None:
        self.authenticate()
        response = self.client.post(
            "/broadcastex/auth",
            json={
                "socket_id": "123.456",
                "channel_name": "private-room",
            },
        )
        expected = hmac.new(
            self.app_secret.encode(),
            b"123.456:private-room",
            hashlib.sha256,
        ).hexdigest()

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json, {"auth": f"{self.app_key}:{expected}"})

    def test_authorizes_presence_room_by_prefix_for_logged_in_identity(self) -> None:
        self.authenticate()
        channel_data = json.dumps(
            {"user_id": "1", "user_info": {}},
            separators=(",", ":"),
        )
        response = self.client.post(
            "/broadcastex/auth",
            json={
                "socket_id": "123.456",
                "channel_name": "presence-room",
                "channel_data": channel_data,
            },
        )
        expected = hmac.new(
            self.app_secret.encode(),
            f"123.456:presence-room:{channel_data}".encode(),
            hashlib.sha256,
        ).hexdigest()

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json, {"auth": f"{self.app_key}:{expected}"})

    def test_rejects_presence_identity_spoofing_and_public_channels(self) -> None:
        self.authenticate()
        spoofed_data = json.dumps(
            {"user_id": "someone-else", "user_info": {}},
            separators=(",", ":"),
        )
        response = self.client.post(
            "/broadcastex/auth",
            json={
                "socket_id": "123.456",
                "channel_name": "presence-room",
                "channel_data": spoofed_data,
            },
        )
        self.assertEqual(response.status_code, 403)

        response = self.client.post(
            "/broadcastex/auth",
            json={
                "socket_id": "123.456",
                "channel_name": "public-room",
            },
        )
        self.assertEqual(response.status_code, 403)

    def test_requires_session_identity_for_page_and_auth(self) -> None:
        response = self.client.get("/")
        self.assertEqual(response.status_code, 302)
        self.assertEqual(response.location, "/login")
        response = self.client.post(
            "/broadcastex/auth",
            json={"socket_id": "123.456", "channel_name": "private-room"},
        )
        self.assertEqual(response.status_code, 401)

    def test_registration_stores_password_hash_and_rejects_duplicate_username(self) -> None:
        self.authenticate()
        with sqlite3.connect(self.app.config["DATABASE"]) as connection:
            row = connection.execute(
                "SELECT username, password_hash FROM users"
            ).fetchone()

        self.assertEqual(row[0], "user_123")
        self.assertNotEqual(row[1], "correct horse battery")

        self.client.post("/logout", data={"csrf_token": self.csrf_token()})
        response = self.client.get("/register")
        token = re.search(rb'name="csrf_token" value="([^"]+)"', response.data)
        response = self.client.post(
            "/register",
            data={
                "csrf_token": token.group(1).decode(),
                "username": "USER_123",
                "password": "another password",
            },
        )
        self.assertEqual(response.status_code, 409)

    def test_login_and_logout_use_session_and_csrf_protection(self) -> None:
        self.authenticate()
        self.client.post("/logout", data={"csrf_token": self.csrf_token()})

        response = self.client.get("/login")
        token = re.search(rb'name="csrf_token" value="([^"]+)"', response.data)
        response = self.client.post(
            "/login",
            data={
                "csrf_token": token.group(1).decode(),
                "username": "USER_123",
                "password": "correct horse battery",
            },
        )
        self.assertEqual(response.status_code, 302)
        self.assertEqual(self.client.get("/").status_code, 200)

        response = self.client.post("/logout", data={"csrf_token": "invalid"})
        self.assertEqual(response.status_code, 400)
        response = self.client.post(
            "/logout",
            data={"csrf_token": self.csrf_token()},
        )
        self.assertEqual(response.status_code, 302)
        self.assertEqual(self.client.get("/").location, "/login")

    def csrf_token(self) -> str:
        with self.client.session_transaction() as browser_session:
            token = browser_session.get("_csrf_token")
        if token is None:
            self.client.get("/")
        with self.client.session_transaction() as browser_session:
            return browser_session["_csrf_token"]


if __name__ == "__main__":
    unittest.main()
