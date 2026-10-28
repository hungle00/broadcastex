defmodule Broadcastex.RouterTest do
  use ExUnit.Case, async: false

  test "publishes REST events to subscribed channel sockets" do
    app_id = "router-app-#{System.unique_integer([:positive])}"
    app_key = "router-key"
    app_secret = "secret"
    channel = "public-test"
    topic = Broadcastex.channel_topic(app_id, channel)

    assert :ok = Broadcastex.AppStore.register_app(app_id, app_key, app_secret)
    assert :ok = Phoenix.PubSub.subscribe(Broadcastex.PubSub, topic)
    on_exit(fn -> Phoenix.PubSub.unsubscribe(Broadcastex.PubSub, topic) end)

    body = Jason.encode!(%{name: "test:event", channels: [channel], data: %{value: 1}})
    timestamp = DateTime.utc_now() |> DateTime.to_unix() |> Integer.to_string()
    body_md5 = :crypto.hash(:md5, body) |> Base.encode16(case: :lower)

    query_params = %{
      "auth_key" => app_key,
      "auth_timestamp" => timestamp,
      "body_md5" => body_md5
    }

    query_string =
      query_params
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join("&", fn {key, value} -> "#{key}=#{value}" end)

    path = "/apps/#{app_id}/events"
    signature = Broadcastex.Auth.hmac_sha256(app_secret, "POST\n#{path}\n#{query_string}")

    conn =
      Plug.Test.conn(
        :post,
        "#{path}?#{query_string}&auth_signature=#{signature}",
        body
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Broadcastex.Router.call([])

    assert conn.status == 200
    assert_receive {:broadcast, payload}

    assert Jason.decode!(payload) == %{
             "event" => "test:event",
             "channel" => channel,
             "data" => %{"value" => 1}
           }
  end
end
