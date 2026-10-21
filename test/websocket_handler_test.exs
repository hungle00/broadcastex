defmodule Broadcastex.WebSocketHandlerTest do
  use ExUnit.Case, async: false

  test "authenticates, subscribes, and unsubscribes a presence channel" do
    app = %{
      app_id: "test-app-#{System.unique_integer([:positive])}",
      key: "app-key",
      secret: "secret"
    }

    channel = "presence-chat"

    {:push, {:text, handshake}, state} = Broadcastex.WebSocketHandler.init(app: app)
    socket_id = Jason.decode!(Jason.decode!(handshake)["data"])["socket_id"]
    channel_data = Jason.encode!(%{user_id: "user-1", user_info: %{name: "Alice"}})

    signature =
      Broadcastex.Auth.hmac_sha256(
        app.secret,
        "#{socket_id}:#{channel}:#{channel_data}"
      )

    subscribe =
      Jason.encode!(%{
        event: "broadcastex:subscribe",
        data: %{
          channel: channel,
          auth: "#{app.key}:#{signature}",
          channel_data: channel_data
        }
      })

    on_exit(fn ->
      Broadcastex.PresenceManager.leave(app.app_id, channel, self())
      Registry.unregister(Broadcastex.ChannelRegistry, "#{app.app_id}:#{channel}")
    end)

    assert {:push, {:text, response}, state} =
             Broadcastex.WebSocketHandler.handle_in({subscribe, opcode: :text}, state)

    assert %{
             "event" => "broadcastex_internal:subscription_succeeded",
             "channel" => ^channel,
             "data" => %{
               "presence" => %{
                 "count" => 1,
                 "ids" => ["user-1"],
                 "hash" => %{"user-1" => %{"name" => "Alice"}}
               }
             }
           } = Jason.decode!(response)

    unsubscribe =
      Jason.encode!(%{
        event: "broadcastex:unsubscribe",
        data: %{channel: channel}
      })

    assert {:ok, %{channels: channels}} =
             Broadcastex.WebSocketHandler.handle_in({unsubscribe, opcode: :text}, state)

    refute MapSet.member?(channels, channel)
  end
end
