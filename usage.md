## Test
1. Use wscat for to open WebSocket connection
```
wscat -c ws://localhost:4000/app/my-key
```

2. Subscribe from wscat client:
```
> {"event": "broadcastex:subscribe", "data": {"channel": "my-channel"}}
< {"event":"broadcastex:subscription_succeeded","channel":"my-channel"}
```

3. Trigger Event qua HTTP API (ví dụ dùng curl ở terminal khác):
```
curl -X POST http://localhost:4000/api/events \
  -H "Content-Type: application/json" \
  -d '{"channel": "my-channel", "event": "new-message", "data": {"user": "Alice", "text": "Hello Elixir!"}}'
```