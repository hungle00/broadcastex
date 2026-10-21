## Test
1. Use wscat for to open WebSocket connection
```
wscat -c ws://localhost:4000/app/my-key
```
2. Use Flask to get Auth token
```
curl -X POST http://localhost:5000/pusher/auth \
  -H "Content-Type: application/json" \
  -d '{"socket_id": "12345.15", "channel_name": "private-chat"}'
```
Flask will response something like:
```
{"auth": "my-app-key:a1b2c3d4e5f6..."}
```
2. Subscribe from wscat client:
```
> {"event": "broadcastex:subscribe", "data": {"channel": "private-chat", "auth": "my-app-key:a1b2c3d4e5f6..."}}
< {"event":"broadcastex:subscription_succeeded","channel":"my-channel"}
```

3. Trigger Event qua HTTP API (ví dụ dùng curl ở terminal khác):
```
curl -X POST http://localhost:4000/api/events \
  -H "Content-Type: application/json" \
  -d '{"channel": "my-channel", "event": "new-message", "data": {"user": "Alice", "text": "Hello Elixir!"}}'
```

## Presence channels

Presence channels use the `presence-` prefix and require a signature over the
exact `channel_data` JSON string:

```text
HMAC_SHA256(app_secret, "<socket_id>:<channel_name>:<channel_data>")
```

Send the channel data and the resulting `app_key:signature` in the subscribe
message. The authenticated `user_id` must be a non-empty string, and
`user_info` must be a JSON object:

```json
{
  "event": "broadcastex:subscribe",
  "data": {
    "channel": "presence-chat",
    "auth": "my-app-key:signature",
    "channel_data": "{\"user_id\":\"user-123\",\"user_info\":{\"name\":\"Alice\"}}"
  }
}
```

On success, `broadcastex_internal:subscription_succeeded` includes
`data.presence` with `ids`, `hash`, and `count`. Other members receive
`broadcastex_internal:member_added` and `broadcastex_internal:member_removed`
with `data.user_id` and `data.user_info`. A user is removed only after their
last socket leaves; disconnects are detected by monitoring the WebSocket
process. Clients can explicitly leave with:

```json
{
  "event": "broadcastex:unsubscribe",
  "data": {
    "channel": "presence-chat"
  }
}
```

## Demo dashboard

Open `/dashboard/<app_id>` to see active channels, connection counts, and
presence user details. The page loads channel data from
`/apps/<app_id>/channels` and refreshes automatically every 5 seconds.

This demo route has no authentication and displays the app secret (hidden
visually until toggled) as well as presence `user_info`. Anyone who can access
the URL can inspect those values; do not expose it to an untrusted network.