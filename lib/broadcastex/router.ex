defmodule Broadcastex.Router do
  use Plug.Router

  plug :match

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    body_reader: {Broadcastex.Router, :cache_raw_body, []}

  plug :dispatch

  def cache_raw_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    conn = Plug.Conn.assign(conn, :raw_body, body)
    {:ok, body, conn}
  end

  # 1. Endpoint WebSocket cho Client kết nối
  get "/app/:app_key" do
    IO.inspect(app_key, label: "🔑 APP KEY RECEIVED")
    case Broadcastex.AppStore.get_app_by_key(app_key) do
      {:ok, app} ->
        IO.inspect(app, label: "✅ APP FOUND")
        conn
        |> WebSockAdapter.upgrade(Broadcastex.WebSocketHandler, [app: app], timeout: 60_000)
        |> halt()
      {:error, :not_found} ->
        send_resp(conn, 404, "Invalid App Key")
    end
  end

  # 2. HTTP REST API Event Trigger
  post "/apps/:app_id/events" do
    with {:ok, app} <- Broadcastex.AppStore.get_app_by_id(app_id),
         raw_body <- conn.assigns[:raw_body],
         true <- Broadcastex.Auth.verify_rest_signature(conn, app.secret, raw_body) do

      %{"name" => event, "channels" => channels, "data" => data} = conn.body_params

      # Dispatch tới tất cả channels của App này trong Registry
      Enum.each(channels, fn channel ->
        registry_key = "#{app.app_id}:#{channel}"

        Registry.dispatch(Broadcastex.ChannelRegistry, registry_key, fn entries ->
          payload = Jason.encode!(%{event: event, channel: channel, data: data})
          for {pid, _} <- entries, do: send(pid, {:broadcast, payload})
        end)
      end)

      send_resp(conn, 200, Jason.encode!(%{status: "ok"}))
    else
      {:error, :not_found} -> send_resp(conn, 404, "App Not Found")
      false -> send_resp(conn, 401, "Unauthorized / Invalid Signature")
    end
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end
end
