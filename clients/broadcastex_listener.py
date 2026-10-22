import asyncio
import hashlib
import hmac
import json
from typing import Any

import websockets

WS_URL = "ws://localhost:4000/app/my-app-key"


class BroadcastexAuth:
    def __init__(self, app_key: str, app_secret: str):
        self.app_key = app_key
        self.app_secret = app_secret

    def generate_private_auth(self, socket_id: str, channel_name: str) -> str:
        string_to_sign = f"{socket_id}:{channel_name}"

        signature = hmac.new(
            self.app_secret.encode("utf-8"),
            string_to_sign.encode("utf-8"),
            hashlib.sha256,
        ).hexdigest()

        return f"{self.app_key}:{signature}"

    def generate_presence_auth(
        self, socket_id: str, channel_name: str, channel_data: str
    ) -> str:
        string_to_sign = f"{socket_id}:{channel_name}:{channel_data}"
        signature = hmac.new(
            self.app_secret.encode("utf-8"),
            string_to_sign.encode("utf-8"),
            hashlib.sha256,
        ).hexdigest()

        return f"{self.app_key}:{signature}"


def make_presence_channel_data(user_id: str, user_info: dict[str, Any]) -> str:
    return json.dumps(
        {"user_id": user_id, "user_info": user_info},
        separators=(",", ":"),
    )


def make_public_subscription_data(channel_name: str) -> dict[str, str]:
    return {"channel": channel_name}


def make_private_subscription_data(
    channel_name: str,
    socket_id: str,
    auth_provider: BroadcastexAuth,
) -> dict[str, str]:
    return {
        "channel": channel_name,
        "auth": auth_provider.generate_private_auth(socket_id, channel_name),
    }


def make_presence_subscription_data(
    channel_name: str,
    socket_id: str,
    auth_provider: BroadcastexAuth,
    user_id: str,
    user_info: dict[str, Any],
) -> dict[str, str]:
    presence_data = make_presence_channel_data(user_id, user_info)
    return {
        "channel": channel_name,
        "auth": auth_provider.generate_presence_auth(
            socket_id, channel_name, presence_data
        ),
        "channel_data": presence_data,
    }


async def send_subscription(websocket: Any, channel_data: dict[str, Any]) -> None:
    message = json.dumps(
        {"event": "broadcastex:subscribe", "data": channel_data},
        separators=(",", ":"),
    )
    await websocket.send(message)


async def subscribe_public_channel(websocket: Any, channel_name: str) -> None:
    await send_subscription(websocket, make_public_subscription_data(channel_name))


async def subscribe_private_channel(
    websocket: Any,
    channel_name: str,
    socket_id: str,
    auth_provider: BroadcastexAuth,
) -> None:
    await send_subscription(
        websocket,
        make_private_subscription_data(channel_name, socket_id, auth_provider),
    )


async def subscribe_presence_channel(
    websocket: Any,
    channel_name: str,
    socket_id: str,
    auth_provider: BroadcastexAuth,
    user_id: str,
    user_info: dict[str, Any],
) -> None:
    await send_subscription(
        websocket,
        make_presence_subscription_data(
            channel_name,
            socket_id,
            auth_provider,
            user_id,
            user_info,
        ),
    )


def handle_presence_subscription_data(data: dict[str, Any]) -> None:
    presence = data.get("presence", {})
    print(
        "[+] Subscribe presence thành công:",
        f"count={presence.get('count')}",
        f"ids={presence.get('ids')}",
        f"members={presence.get('hash')}",
    )


def handle_presence_member_added(data: dict[str, Any]) -> None:
    print(
        "[+] Member mới:",
        f"user_id={data.get('user_id')}",
        f"user_info={data.get('user_info')}",
    )


def handle_presence_member_removed(data: dict[str, Any]) -> None:
    print(
        "[-] Member rời channel:",
        f"user_id={data.get('user_id')}",
        f"user_info={data.get('user_info')}",
    )


def handle_server_message(message: str) -> None:
    message_data = json.loads(message)
    event = message_data.get("event")
    data = message_data.get("data", {})

    if (
        event == "broadcastex_internal:subscription_succeeded"
        and isinstance(data, dict)
        and "presence" in data
    ):
        handle_presence_subscription_data(data)
    elif event == "broadcastex_internal:member_added":
        handle_presence_member_added(data)
    elif event == "broadcastex_internal:member_removed":
        handle_presence_member_removed(data)
    else:
        print(f"\n[📩 RECEIVED MESSAGE]: {message}")


async def listen_broadcastex() -> None:
    print(f"[*] Đang kết nối tới Broadcastex Server: {WS_URL}")
    auth_provider = BroadcastexAuth(
        app_key="my-app-key",
        app_secret="my-app-secret",
    )

    async with websockets.connect(WS_URL) as websocket:
        handshake_data = json.loads(await websocket.recv())
        if handshake_data.get("event") != "broadcastex:connection_established":
            raise RuntimeError("Broadcastex server không trả về handshake hợp lệ")

        connection_data = json.loads(handshake_data["data"])
        socket_id = connection_data.get("socket_id")
        if not isinstance(socket_id, str):
            raise RuntimeError("Handshake không chứa socket_id hợp lệ")
        print(f"[+] Handshake thành công! Socket ID: {socket_id}")

        # Đổi hàm subscribe tại đây để thử public/private channel.
        await subscribe_presence_channel(
            websocket,
            channel_name="presence-chat",
            socket_id=socket_id,
            auth_provider=auth_provider,
            user_id="user-123",
            user_info={"name": "Alice"},
        )

        print("[*] Đang lắng nghe sự kiện từ server... (Nhấn Ctrl+C để thoát)")
        async for message in websocket:
            handle_server_message(message)

if __name__ == "__main__":
    try:
        asyncio.run(listen_broadcastex())
    except KeyboardInterrupt:
        print("\n[*] Đã ngắt kết nối client.")
