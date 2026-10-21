defmodule Broadcastex.DashboardTest do
  use ExUnit.Case, async: false

  test "serves the dashboard template and returns app/channel data as JSON" do
    app_id = "dashboard-app-#{System.unique_integer([:positive])}"
    app_key = "dashboard-key"
    app_secret = "secret<&"
    presence_channel = "presence-dashboard"
    public_channel = "dashboard-public"
    socket_id = "dashboard-socket"

    assert :ok = Broadcastex.AppStore.register_app(app_id, app_key, app_secret)

    assert :ok =
             Broadcastex.PresenceManager.track_subscription(
               app_id,
               public_channel,
               socket_id,
               self()
             )

    assert {:ok, %{count: 1}} =
             Broadcastex.PresenceManager.join(
               app_id,
               presence_channel,
               socket_id,
               self(),
               "<user>",
               %{"bio" => "<script>alert(1)</script>"}
             )

    on_exit(fn ->
      Broadcastex.PresenceManager.leave(app_id, public_channel, self())
      Broadcastex.PresenceManager.leave(app_id, presence_channel, self())
    end)

    dashboard_conn =
      Plug.Test.conn(:get, "/dashboard/#{app_id}")
      |> Broadcastex.Router.call([])

    assert dashboard_conn.status == 200

    assert Plug.Conn.get_resp_header(dashboard_conn, "content-type") == [
             "text/html; charset=utf-8"
           ]

    assert Plug.Conn.get_resp_header(dashboard_conn, "cache-control") == ["no-store"]
    assert dashboard_conn.resp_body =~ "class=\"stat-card\""
    assert dashboard_conn.resp_body =~ "class=\"panel\""
    assert dashboard_conn.resp_body =~ ".badge {"
    assert dashboard_conn.resp_body =~ "badge.className ="
    assert dashboard_conn.resp_body =~ "setInterval(loadChannels, 5000)"

    assert dashboard_conn.resp_body =~
             "info.textContent = JSON.stringify(user.user_info, null, 2)"

    refute dashboard_conn.resp_body =~ "info.innerHTML"

    channels_conn =
      Plug.Test.conn(:get, "/apps/#{app_id}/channels")
      |> Broadcastex.Router.call([])

    assert channels_conn.status == 200

    assert Plug.Conn.get_resp_header(channels_conn, "content-type") == [
             "application/json; charset=utf-8"
           ]

    assert Plug.Conn.get_resp_header(channels_conn, "cache-control") == ["no-store"]

    response = Jason.decode!(channels_conn.resp_body)
    assert response["app"]["id"] == app_id
    assert response["app"]["key"] == app_key
    assert response["app"]["secret"] == app_secret
    assert response["channel_count"] == 2
    assert response["subscription_count"] == 2
    assert Enum.any?(response["channels"], &(&1["name"] == public_channel))

    assert %{
             "type" => "presence",
             "subscription_count" => 1,
             "socket_count" => 1,
             "users" => [
               %{
                 "user_id" => "<user>",
                 "user_info" => %{"bio" => "<script>alert(1)</script>"},
                 "socket_count" => 1
               }
             ]
           } = Enum.find(response["channels"], &(&1["name"] == presence_channel))
  end

  test "returns 404 for channels of an unknown app" do
    conn =
      Plug.Test.conn(:get, "/apps/missing-app-#{System.unique_integer([:positive])}/channels")
      |> Broadcastex.Router.call([])

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body) == %{"error" => "App Not Found"}
  end
end
