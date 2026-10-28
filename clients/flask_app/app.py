import hmac
import os
import re
import secrets
import sqlite3
from collections.abc import Callable
from dataclasses import dataclass
from functools import wraps
from pathlib import Path
from typing import Any
from urllib.parse import quote

from flask import (
    Flask,
    abort,
    g,
    jsonify,
    redirect,
    render_template,
    request,
    send_from_directory,
    session,
    url_for,
)
from werkzeug.exceptions import BadRequest
from werkzeug.security import check_password_hash, generate_password_hash

from clients.python.broadcastex import BroadcastexAuth


FLASK_APP_DIR = Path(__file__).resolve().parent
JAVASCRIPT_CLIENT_DIR = FLASK_APP_DIR.parent / "javascript"
USERNAME_PATTERN = re.compile(r"^[A-Za-z0-9_]{3,32}$")
MIN_PASSWORD_LENGTH = 8
MAX_PASSWORD_LENGTH = 1024


@dataclass(frozen=True)
class SessionUser:
    user_id: str

    def get_id(self) -> str:
        return self.user_id


def current_user() -> SessionUser | None:
    user_id = session.get("user_id")
    if isinstance(user_id, str) and user_id:
        return SessionUser(user_id)
    return None


def login_required(view: Callable[..., Any]) -> Callable[..., Any]:
    @wraps(view)
    def wrapped(*args: Any, **kwargs: Any) -> Any:
        if current_user() is None:
            if request.path.startswith("/broadcastex/"):
                abort(401)
            return redirect(url_for("login"))
        return view(*args, **kwargs)

    return wrapped


def create_app(config: dict[str, Any] | None = None) -> Flask:
    app = Flask(
        __name__,
        template_folder=str(FLASK_APP_DIR / "templates"),
        static_folder=None,
    )
    app.config.from_mapping(
        SECRET_KEY=os.environ.get("FLASK_SECRET_KEY", ""),
        BROADCASTEX_APP_KEY=os.environ.get("BROADCASTEX_APP_KEY", ""),
        BROADCASTEX_APP_SECRET=os.environ.get("BROADCASTEX_APP_SECRET", ""),
        BROADCASTEX_WS_URL=os.environ.get("BROADCASTEX_WS_URL", "ws://localhost:4000"),
        DATABASE=os.environ.get(
            "DATABASE_PATH",
            str(Path(app.instance_path) / "users.sqlite3"),
        ),
    )
    if config:
        app.config.update(config)
    if not app.config["SECRET_KEY"]:
        raise RuntimeError("FLASK_SECRET_KEY is not configured")

    def get_db() -> sqlite3.Connection:
        if "db" not in g:
            g.db = sqlite3.connect(app.config["DATABASE"], timeout=10)
            g.db.row_factory = sqlite3.Row
        return g.db

    def initialize_database() -> None:
        database_path = Path(app.config["DATABASE"])
        database_path.parent.mkdir(parents=True, exist_ok=True)

        with sqlite3.connect(database_path, timeout=10) as connection:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS users (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    username TEXT NOT NULL COLLATE NOCASE UNIQUE,
                    password_hash TEXT NOT NULL,
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                )
                """
            )

    @app.teardown_appcontext
    def close_db(_error: BaseException | None) -> None:
        database = g.pop("db", None)
        if database is not None:
            database.close()

    def csrf_token() -> str:
        token = session.get("_csrf_token")
        if not isinstance(token, str):
            token = secrets.token_urlsafe(32)
            session["_csrf_token"] = token
        return token

    def validate_csrf_token() -> None:
        submitted = request.form.get("csrf_token")
        expected = session.get("_csrf_token")
        if (
            not isinstance(submitted, str)
            or not isinstance(expected, str)
            or not hmac.compare_digest(submitted, expected)
        ):
            abort(400, description="Invalid CSRF token")

    initialize_database()

    def get_auth_provider() -> BroadcastexAuth:
        try:
            return BroadcastexAuth(
                app.config["BROADCASTEX_APP_KEY"],
                app.config["BROADCASTEX_APP_SECRET"],
            )
        except ValueError as error:
            raise RuntimeError("Broadcastex credentials are not configured") from error

    def get_user_id() -> str:
        user = current_user()
        user_id = user.get_id() if hasattr(user, "get_id") else None
        if not isinstance(user_id, str) or not user_id:
            abort(401)
        return user_id

    @app.get("/login")
    def login() -> str:
        if current_user() is not None:
            return redirect(url_for("index"))
        return render_template("auth.html", mode="login", csrf_token=csrf_token())

    @app.post("/login")
    def login_submit():
        validate_csrf_token()
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")

        user = get_db().execute(
            "SELECT id, password_hash FROM users WHERE username = ? COLLATE NOCASE",
            (username,),
        ).fetchone()

        if (
            user is None
            or len(password) > MAX_PASSWORD_LENGTH
            or not check_password_hash(user["password_hash"], password)
        ):
            return (
                render_template(
                    "auth.html",
                    mode="login",
                    csrf_token=csrf_token(),
                    error="Invalid username or password",
                    username=username,
                ),
                401,
            )

        session.clear()
        session["user_id"] = str(user["id"])
        return redirect(url_for("index"))

    @app.get("/register")
    def register() -> str:
        if current_user() is not None:
            return redirect(url_for("index"))
        return render_template("auth.html", mode="register", csrf_token=csrf_token())

    @app.post("/register")
    def register_submit():
        validate_csrf_token()
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")

        if not USERNAME_PATTERN.fullmatch(username):
            return (
                render_template(
                    "auth.html",
                    mode="register",
                    csrf_token=csrf_token(),
                    error="Username must be 3–32 letters, numbers, or underscores.",
                    username=username,
                ),
                400,
            )

        if not MIN_PASSWORD_LENGTH <= len(password) <= MAX_PASSWORD_LENGTH:
            return (
                render_template(
                    "auth.html",
                    mode="register",
                    csrf_token=csrf_token(),
                    error=f"Password must be {MIN_PASSWORD_LENGTH}–{MAX_PASSWORD_LENGTH} characters.",
                    username=username,
                ),
                400,
            )

        password_hash = generate_password_hash(password)
        try:
            cursor = get_db().execute(
                "INSERT INTO users (username, password_hash) VALUES (?, ?)",
                (username, password_hash),
            )
            get_db().commit()
        except sqlite3.IntegrityError:
            return (
                render_template(
                    "auth.html",
                    mode="register",
                    csrf_token=csrf_token(),
                    error="That username is already registered.",
                    username=username,
                ),
                409,
            )

        session.clear()
        session["user_id"] = str(cursor.lastrowid)
        return redirect(url_for("index"))

    @app.post("/logout")
    @login_required
    def logout():
        validate_csrf_token()
        session.clear()
        return redirect(url_for("login"))

    @app.get("/")
    @login_required
    def index() -> str:
        user_id = get_user_id()
        app_key = app.config["BROADCASTEX_APP_KEY"]
        if not app_key:
            raise RuntimeError("BROADCASTEX_APP_KEY is not configured")

        websocket_url = (
            f"{app.config['BROADCASTEX_WS_URL'].rstrip('/')}"
            f"/app/{quote(app_key, safe='')}"
        )
        return render_template(
            "example.html",
            websocket_url=websocket_url,
            user_id=user_id,
            csrf_token=csrf_token(),
        )

    @app.get("/broadcastex.js")
    @login_required
    def javascript_client():
        return send_from_directory(JAVASCRIPT_CLIENT_DIR, "broadcastex.js")

    @app.post("/broadcastex/auth")
    @login_required
    def authorize_channel():
        if not request.is_json:
            return jsonify(error="Expected application/json"), 400

        try:
            payload = request.get_json()
        except BadRequest:
            return jsonify(error="Invalid JSON body"), 400

        if not isinstance(payload, dict):
            return jsonify(error="Invalid JSON body"), 400

        socket_id = payload.get("socket_id")
        channel_name = payload.get("channel_name")
        channel_data = payload.get("channel_data")
        if not isinstance(channel_name, str):
            return jsonify(error="channel_name is required"), 400

        try:
            authorization = get_auth_provider().authorize(
                socket_id,
                channel_name,
                channel_data,
                get_user_id(),
            )
        except ValueError as error:
            return jsonify(error=str(error)), 400
        except PermissionError as error:
            return jsonify(error=str(error)), 403

        return jsonify(authorization)

    return app


if __name__ == "__main__":
    app = create_app()
    app.run(host="127.0.0.1", port=5000)
