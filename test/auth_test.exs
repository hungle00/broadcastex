defmodule Broadcastex.AuthTest do
  use ExUnit.Case, async: true

  test "verifies a presence signature against the exact channel data" do
    secret = "test-secret"
    socket_id = "123.456"
    channel = "presence-chat"
    channel_data = ~s({"user_id":"user-1","user_info":{"name":"Alice"}})
    signature = Broadcastex.Auth.hmac_sha256(secret, "#{socket_id}:#{channel}:#{channel_data}")
    auth = "app-key:#{signature}"

    assert Broadcastex.Auth.verify_presence_auth(
             auth,
             secret,
             socket_id,
             channel,
             channel_data
           )

    refute Broadcastex.Auth.verify_presence_auth(
             auth,
             secret,
             socket_id,
             channel,
             channel_data <> " "
           )
  end
end
