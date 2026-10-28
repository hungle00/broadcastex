# Broadcastex clients

Client implementations and the Flask demo are separated by role:

```text
clients/
├── python/
│   ├── broadcastex.py       # Python auth/signing helper
│   ├── sender.py            # REST event sender example
│   └── requirements.txt     # sender dependencies
├── javascript/
│   ├── broadcastex.js       # browser WebSocket client
│   └── broadcastex.test.cjs # JavaScript client tests
└── flask_app/
    ├── app.py               # Flask demo, auth, and SQLite users
    ├── templates/
    ├── test_app.py
    └── requirements.txt
```

## Flask demo

From the repository root, install Flask and configure the app:

```sh
python -m pip install -r clients/flask_app/requirements.txt
export FLASK_SECRET_KEY=replace-with-a-long-random-value
export BROADCASTEX_APP_KEY=my-app-key
export BROADCASTEX_APP_SECRET=my-app-secret
export BROADCASTEX_WS_URL=ws://localhost:4000
python -m clients.flask_app.app
```

Open `http://127.0.0.1:5000/register` to create an account. Usernames and
Werkzeug password hashes are stored in SQLite at
`clients/flask_app/instance/users.sqlite3` by default. Set `DATABASE_PATH` to
choose another database file. Passwords are never stored in plain text.

The app serves the JavaScript client and demo page. It uses Flask's signed
session, and login, registration, and logout forms use CSRF tokens.

The auth helper signs any channel beginning with `private-` or `presence-`.
All logged-in users are currently allowed to subscribe to any channel with
those prefixes. Presence channel data must contain the authenticated user's ID
and an empty `user_info` object; the Flask endpoint rejects attempts to
impersonate another user. Add application-specific authorization in
`python/broadcastex.py` if access should be restricted by room or user.

Run Flask tests from the repository root:

```sh
python -m unittest clients.flask_app.test_app
```

## Python helper and sender

The signing helper is `python/broadcastex.py`. The REST sender example is
`python/sender.py` and uses `requests`:

```sh
python -m pip install -r clients/python/requirements.txt
python clients/python/sender.py
```

## JavaScript client

`javascript/broadcastex.js` is the browser WebSocket client. The Flask app
serves it at `/broadcastex.js`. It supports public/private/presence
subscriptions, event callbacks, and presence member callbacks. Private and
presence auth is requested from the Flask app; keep the Broadcastex app secret
on the server.

Run its tests from the repository root:

```sh
node --test clients/javascript/broadcastex.test.cjs
```
