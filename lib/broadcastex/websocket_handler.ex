defmodule Broadcastex.WebSocketHandler do
  @behaviour WebSock

  @impl true
  def init(_args) do
    # Khi client vừa kết nối, gửi handshake event `broadcastex:connection_established`
    handshake_payload = Jason.encode!(%{
      event: "broadcastex:connection_established",
      data: Jason.encode!(%{socket_id: inspect(self()), activity_timeout: 120})
    })

    {:push, {:text, handshake_payload}, %{subscribed_channels: MapSet.new()}}
  end

  # Xử lý frame JSON gửi từ Client lên (Subscribe event)
  @impl true
  def handle_in({msg, [opcode: :text]}, state) do
    IO.inspect(msg, label: "🟢 TEXT PAYLOAD RECEIVED")
    case Jason.decode(msg) do
      {:ok, %{"event" => "broadcastex:subscribe", "data" => %{"channel" => channel}}} ->
        # Đăng ký PID của process hiện tại vào Registry với key là tên channel
        Registry.register(Broadcastex.ChannelRegistry, channel, nil)

        new_state = Map.update!(state, :subscribed_channels, &MapSet.put(&1, channel))

        # Gửi phản hồi subscribe thành công
        response = Jason.encode!(%{event: "broadcastex:subscription_succeeded", channel: channel})
        {:push, {:text, response}, new_state}

      _ ->
        {:ok, state}
    end
  end

  # Catch-all cho các loại opcode khác (như binary, v.v.)
  @impl true
  def handle_in({_payload, [opcode: opcode]}, state) do
    IO.inspect(opcode, label: "⚠️ UNHANDLED OPCODE")
    {:ok, state}
  end

  # Xử lý message nội bộ từ BEAM Mailbox (khi HTTP Router bắn send(pid, {:broadcast, payload}))
  @impl true
  def handle_info({:broadcast, payload}, state) do
    {:push, {:text, payload}, state}
  end

  @impl true
  def terminate(_reason, _state) do
    # Khi client ngắt kết nối, Registry tự động cleanup PID khỏi channel mà không cần code thêm
    :ok
  end
end
