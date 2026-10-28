import hashlib
import hmac
import json
from typing import Any


class BroadcastexAuth:
    def __init__(self, app_key: str, app_secret: str) -> None:
        if not app_key or not app_secret:
            raise ValueError("Broadcastex app key and secret are required")

        self.app_key = app_key
        self.app_secret = app_secret

    def authorize(
        self,
        socket_id: str,
        channel_name: str,
        channel_data: str | None,
        authenticated_user_id: str,
    ) -> dict[str, str]:
        if not isinstance(socket_id, str) or not socket_id or len(socket_id) > 128:
            raise ValueError("Invalid socket_id")

        if channel_name.startswith("private-"):
            signature = self._sign(f"{socket_id}:{channel_name}")
            return {"auth": f"{self.app_key}:{signature}"}

        if channel_name.startswith("presence-"):
            self._validate_presence_data(channel_data, authenticated_user_id)
            signature = self._sign(
                f"{socket_id}:{channel_name}:{channel_data}"
            )
            return {"auth": f"{self.app_key}:{signature}"}

        raise PermissionError("Not authorized to subscribe to this channel")

    def _sign(self, message: str) -> str:
        return hmac.new(
            self.app_secret.encode("utf-8"),
            message.encode("utf-8"),
            hashlib.sha256,
        ).hexdigest()

    @staticmethod
    def _validate_presence_data(
        channel_data: str | None, authenticated_user_id: str
    ) -> None:
        if not isinstance(channel_data, str):
            raise ValueError("Presence channel_data is required")

        try:
            decoded: Any = json.loads(channel_data)
        except json.JSONDecodeError as error:
            raise ValueError("Invalid presence channel_data") from error

        if (
            not isinstance(decoded, dict)
            or decoded.get("user_id") != authenticated_user_id
            or decoded.get("user_info") != {}
        ):
            raise PermissionError("Presence identity does not match the logged-in user")
