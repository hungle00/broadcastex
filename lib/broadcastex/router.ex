defmodule Broadcastex.Router do
  use Plug.Router

  plug :match
  plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason
  plug :dispatch

  # 1. Endpoint WebSocket cho Client kết nối
  get "/app/:app_key" do
    conn
    |> WebSockAdapter.upgrade(Broadcastex.WebSocketHandler, [], timeout: 60_000)
    |> halt()
  end

  # 2. API Trigger Event (Publish message)
  post "/api/events" do
    %{"channel" => channel, "event" => event, "data" => data} = conn.body_params
    IO.inspect({channel, event, data})
    # Dispatch message tới tất cả các Process đã đăng ký channel này
    Registry.dispatch(Broadcastex.ChannelRegistry, channel, fn entries ->
      payload = Jason.encode!(%{event: event, channel: channel, data: data})

      for {pid, _value} <- entries do
        send(pid, {:broadcast, payload})
      end
    end)

    send_resp(conn, 200, Jason.encode!(%{status: "ok"}))
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end
end
