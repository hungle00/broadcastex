defmodule Broadcastex.WebSocketHandler do
  @behaviour WebSock

  @impl true
  def init(app: app) do
    socket_id =
      "#{System.unique_integer([:positive])}.#{inspect(self()) |> String.replace(~r/[^\d]/, "")}"

    handshake =
      Jason.encode!(%{
        event: "broadcastex:connection_established",
        data: Jason.encode!(%{socket_id: socket_id, activity_timeout: 120})
      })

    state = %{
      app: app,
      socket_id: socket_id,
      channels: MapSet.new()
    }

    {:push, {:text, handshake}, state}
  end

  @impl true
  def handle_in({msg, [opcode: :text]}, state) do
    case Jason.decode(msg) do
      {:ok, %{"event" => "broadcastex:subscribe", "data" => data}} when is_map(data) ->
        subscribe(data, state)

      {:ok, %{"event" => "broadcastex:unsubscribe", "data" => data}} when is_map(data) ->
        unsubscribe(data, state)

      _ ->
        {:ok, state}
    end
  end

  @impl true
  def handle_in({_payload, [opcode: _opcode]}, state), do: {:ok, state}

  @impl true
  def handle_info({:broadcast, payload}, state) do
    {:push, {:text, payload}, state}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  defp subscribe(%{"channel" => channel} = data, state) when is_binary(channel) do
    with {:ok, subscription} <- authorize_subscription(channel, data, state),
         :ok <- register_channel(channel, state) do
      finish_subscription(channel, subscription, state)
    else
      {:error, reason} -> push_error(reason, state)
    end
  end

  defp subscribe(_data, state), do: push_error("Channel is required", state)

  defp authorize_subscription("presence-" <> _ = channel, data, state) do
    with {:ok, channel_data} when is_binary(channel_data) <-
           Map.fetch(data, "channel_data"),
         true <-
           Broadcastex.Auth.verify_presence_auth(
             Map.get(data, "auth"),
             state.app.secret,
             state.socket_id,
             channel,
             channel_data
           ),
         {:ok, decoded_data} when is_map(decoded_data) <- Jason.decode(channel_data),
         {:ok, user_id, user_info} <- presence_identity(decoded_data) do
      {:ok, {:presence, user_id, user_info}}
    else
      :error -> {:error, "Presence channel_data is required"}
      false -> {:error, "Invalid presence auth signature"}
      {:error, _reason} -> {:error, "Invalid presence channel_data"}
      {:ok, _invalid_data} -> {:error, "Invalid presence channel_data"}
    end
  end

  defp authorize_subscription("private-" <> _ = channel, data, state) do
    case Map.get(data, "auth") do
      auth when is_binary(auth) ->
        if Broadcastex.Auth.verify_channel_auth(
             auth,
             state.app.secret,
             state.socket_id,
             channel
           ) do
          {:ok, :regular}
        else
          {:error, "Invalid auth signature"}
        end

      _ ->
        {:error, "Auth token required for private channel"}
    end
  end

  defp authorize_subscription(_public_channel, _data, _state), do: {:ok, :regular}

  defp presence_identity(%{"user_id" => user_id, "user_info" => user_info})
       when is_binary(user_id) and user_id != "" and is_map(user_info) do
    {:ok, user_id, user_info}
  end

  defp presence_identity(_data), do: {:error, :invalid_presence_identity}

  defp register_channel(channel, state) do
    if MapSet.member?(state.channels, channel) do
      :ok
    else
      registry_key = "#{state.app.app_id}:#{channel}"

      case Registry.register(Broadcastex.ChannelRegistry, registry_key, nil) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, "Could not register channel: #{inspect(reason)}"}
      end
    end
  end

  defp finish_subscription(channel, :regular, state) do
    state = %{state | channels: MapSet.put(state.channels, channel)}
    push_subscription_succeeded(channel, nil, state)
  end

  defp finish_subscription(channel, {:presence, user_id, user_info}, state) do
    case Broadcastex.PresenceManager.join(
           state.app.app_id,
           channel,
           state.socket_id,
           self(),
           user_id,
           user_info
         ) do
      {:ok, presence} ->
        state = %{state | channels: MapSet.put(state.channels, channel)}
        push_subscription_succeeded(channel, presence, state)

      {:error, reason} ->
        unregister_if_new(channel, state)
        push_error("Could not join presence channel: #{inspect(reason)}", state)
    end
  end

  defp push_subscription_succeeded(channel, nil, state) do
    response =
      Jason.encode!(%{
        event: "broadcastex_internal:subscription_succeeded",
        channel: channel
      })

    {:push, {:text, response}, state}
  end

  defp push_subscription_succeeded(channel, presence, state) do
    response =
      Jason.encode!(%{
        event: "broadcastex_internal:subscription_succeeded",
        channel: channel,
        data: %{presence: presence}
      })

    {:push, {:text, response}, state}
  end

  defp unsubscribe(%{"channel" => channel}, state) when is_binary(channel) do
    if MapSet.member?(state.channels, channel) do
      if String.starts_with?(channel, "presence-") do
        :ok = Broadcastex.PresenceManager.leave(state.app.app_id, channel, self())
      end

      Registry.unregister(Broadcastex.ChannelRegistry, "#{state.app.app_id}:#{channel}")
      {:ok, %{state | channels: MapSet.delete(state.channels, channel)}}
    else
      {:ok, state}
    end
  end

  defp unsubscribe(_data, state), do: push_error("Channel is required", state)

  defp unregister_if_new(channel, state) do
    unless MapSet.member?(state.channels, channel) do
      Registry.unregister(Broadcastex.ChannelRegistry, "#{state.app.app_id}:#{channel}")
    end
  end

  defp push_error(message, state) do
    response = Jason.encode!(%{event: "broadcastex:error", data: %{message: message}})
    {:push, {:text, response}, state}
  end
end
