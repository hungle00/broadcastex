defmodule Broadcastex.WebSocketHandler do
  @behaviour WebSock

  @impl true
  def init([app: app]) do
    # Socket ID duy nhất dựa trên PID của Process hiện tại
    socket_id = "#{System.unique_integer([:positive])}.#{inspect(self()) |> String.replace(~r/[^\d]/, "")}"
    # Khi client vừa kết nối, gửi handshake event `broadcastex:connection_established`
    handshake = Jason.encode!(%{
      event: "broadcastex:connection_established",
      data: Jason.encode!(%{socket_id: socket_id, activity_timeout: 120})
    })

    state = %{
      app: app,
      socket_id: socket_id,
      channels: MapSet.new(),
    }

    {:push, {:text, handshake}, state}
  end

  # Xử lý frame JSON gửi từ Client lên (Subscribe event)
  @impl true
  def handle_in({msg, [opcode: :text]}, state) do
    IO.inspect(msg, label: "🟢 TEXT PAYLOAD RECEIVED")
    case Jason.decode(msg) do
      {:ok, %{"event" => "broadcastex:subscribe", "data" => data}} ->
        channel = Map.fetch!(data, "channel")
        auth = Map.get(data, "auth")

        case handle_subscribe(channel, auth, state) do
          :ok ->
            registry_key = "#{state.app.app_id}:#{channel}"
            Registry.register(Broadcastex.ChannelRegistry, registry_key, nil)

            new_state = Map.update!(state, :channels, &MapSet.put(&1, channel))
            res = Jason.encode!(%{event: "broadcastex_internal:subscription_succeeded", channel: channel})
            {:push, {:text, res}, new_state}

          {:error, reason} ->
            err = Jason.encode!(%{event: "broadcastex:error", data: %{message: reason}})
            {:push, {:text, err}, state}
        end

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

  # Kiểm tra Subscribe
  defp handle_subscribe("private-" <> _rest = channel, auth, state) do
    cond do
      is_nil(auth) ->
        {:error, "Auth token required for private channel"}
      Broadcastex.Auth.verify_channel_auth(auth, state.app.secret, state.socket_id, channel) ->
        :ok
      true ->
        {:error, "Invalid auth signature"}
    end
  end

  defp handle_subscribe(_public_channel, _auth, _state), do: :ok

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
