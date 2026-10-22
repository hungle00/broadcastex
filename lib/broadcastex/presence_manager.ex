defmodule Broadcastex.PresenceManager do
  use GenServer

  @table :broadcastex_presence

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def join(app_id, channel, socket_id, pid, user_id, user_info) do
    GenServer.call(__MODULE__, {:join, app_id, channel, socket_id, pid, user_id, user_info})
  end

  def leave(app_id, channel, pid) do
    GenServer.call(__MODULE__, {:leave, app_id, channel, pid})
  end

  def track_subscription(app_id, channel, socket_id, pid) do
    GenServer.call(__MODULE__, {:track_subscription, app_id, channel, socket_id, pid})
  end

  def dashboard_snapshot(app_id) do
    GenServer.call(__MODULE__, {:dashboard_snapshot, app_id})
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{connections: %{}}}
  end

  @impl true
  def handle_call(
        {:join, app_id, channel, socket_id, pid, user_id, user_info},
        _from,
        state
      ) do
    membership = {app_id, channel, user_id}

    case connection_membership(state, pid, app_id, channel, socket_id, user_id) do
      :ok ->
        join_membership(membership, socket_id, pid, user_info, state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:track_subscription, app_id, channel, socket_id, pid},
        _from,
        state
      ) do
    case connection_socket(state, pid, socket_id) do
      :ok ->
        state = add_subscription(state, app_id, channel, socket_id, pid)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:leave, app_id, channel, pid}, _from, state) do
    state =
      case Map.get(state.connections, pid) do
        nil ->
          state

        connection ->
          connection.subscriptions
          |> Enum.filter(fn {member_app_id, member_channel} ->
            member_app_id == app_id and member_channel == channel
          end)
          |> Enum.reduce(state, fn subscription, acc ->
            remove_subscription(acc, pid, subscription)
          end)
      end

    {:reply, :ok, state}
  end

  def handle_call({:dashboard_snapshot, app_id}, _from, state) do
    {:reply, build_dashboard_snapshot(app_id, state), state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.connections, pid) do
      %{ref: ^ref} = connection ->
        state =
          Enum.reduce(connection.presence_memberships, state, fn membership, acc ->
            remove_membership(acc, pid, connection.socket_id, membership)
          end)

        {:noreply, %{state | connections: Map.delete(state.connections, pid)}}

      _ ->
        {:noreply, state}
    end
  end

  defp join_membership(membership, socket_id, pid, user_info, state) do
    case :ets.lookup(@table, membership) do
      [] ->
        state = add_subscription(state, elem(membership, 0), elem(membership, 1), socket_id, pid)
        :ets.insert(@table, {membership, user_info, MapSet.new([socket_id])})
        state = add_presence_membership(state, pid, membership)
        broadcast_member(membership, "added", user_info, pid, state)

        {:reply, {:ok, snapshot(elem(membership, 0), elem(membership, 1))}, state}

      [{^membership, ^user_info, socket_ids}] ->
        state = add_subscription(state, elem(membership, 0), elem(membership, 1), socket_id, pid)
        :ets.insert(@table, {membership, user_info, MapSet.put(socket_ids, socket_id)})
        state = add_presence_membership(state, pid, membership)
        {:reply, {:ok, snapshot(elem(membership, 0), elem(membership, 1))}, state}

      [{^membership, _existing_user_info, _socket_ids}] ->
        {:reply, {:error, :user_info_mismatch}, state}
    end
  end

  defp connection_membership(state, pid, app_id, channel, socket_id, user_id) do
    case Map.get(state.connections, pid) do
      nil ->
        :ok

      %{socket_id: existing_socket_id} when existing_socket_id != socket_id ->
        {:error, :socket_id_mismatch}

      connection ->
        case Enum.find(connection.presence_memberships, fn
               {member_app_id, member_channel, _member_user_id} ->
                 member_app_id == app_id and member_channel == channel
             end) do
          nil -> :ok
          {^app_id, ^channel, ^user_id} -> :ok
          _membership -> {:error, :user_identity_mismatch}
        end
    end
  end

  defp connection_socket(state, pid, socket_id) do
    case Map.get(state.connections, pid) do
      nil -> :ok
      %{socket_id: ^socket_id} -> :ok
      _connection -> {:error, :socket_id_mismatch}
    end
  end

  defp add_subscription(state, app_id, channel, socket_id, pid) do
    state = ensure_connection(state, pid, socket_id)
    connection = Map.fetch!(state.connections, pid)
    subscriptions = MapSet.put(connection.subscriptions, {app_id, channel})
    connection = %{connection | subscriptions: subscriptions}
    %{state | connections: Map.put(state.connections, pid, connection)}
  end

  defp add_presence_membership(state, pid, membership) do
    connection = Map.fetch!(state.connections, pid)
    presence_memberships = MapSet.put(connection.presence_memberships, membership)
    connection = %{connection | presence_memberships: presence_memberships}
    %{state | connections: Map.put(state.connections, pid, connection)}
  end

  defp ensure_connection(state, pid, socket_id) do
    case Map.get(state.connections, pid) do
      nil ->
        ref = Process.monitor(pid)

        connection = %{
          ref: ref,
          socket_id: socket_id,
          subscriptions: MapSet.new(),
          presence_memberships: MapSet.new()
        }

        %{state | connections: Map.put(state.connections, pid, connection)}

      _connection ->
        state
    end
  end

  defp remove_membership(state, pid, socket_id, membership) do
    case :ets.lookup(@table, membership) do
      [{^membership, user_info, socket_ids}] ->
        remaining_socket_ids = MapSet.delete(socket_ids, socket_id)

        if MapSet.size(remaining_socket_ids) == 0 do
          :ets.delete(@table, membership)
          broadcast_member(membership, "removed", user_info, pid, state)
        else
          :ets.insert(@table, {membership, user_info, remaining_socket_ids})
        end

      [] ->
        :ok
    end

    update_presence_membership(state, pid, membership)
  end

  defp remove_subscription(state, pid, {app_id, channel} = subscription) do
    presence_memberships =
      case Map.get(state.connections, pid) do
        nil ->
          []

        connection ->
          Enum.filter(connection.presence_memberships, fn
            {^app_id, ^channel, _user_id} -> true
            _membership -> false
          end)
      end

    state =
      Enum.reduce(presence_memberships, state, fn membership, acc ->
        connection = Map.fetch!(acc.connections, pid)
        remove_membership(acc, pid, connection.socket_id, membership)
      end)

    update_subscription(state, pid, subscription)
  end

  defp update_presence_membership(state, pid, membership) do
    case Map.get(state.connections, pid) do
      nil ->
        state

      connection ->
        presence_memberships = MapSet.delete(connection.presence_memberships, membership)
        connection = %{connection | presence_memberships: presence_memberships}
        %{state | connections: Map.put(state.connections, pid, connection)}
    end
  end

  defp update_subscription(state, pid, subscription) do
    case Map.get(state.connections, pid) do
      nil ->
        state

      connection ->
        subscriptions = MapSet.delete(connection.subscriptions, subscription)

        if MapSet.size(subscriptions) == 0 do
          Process.demonitor(connection.ref, [:flush])
          %{state | connections: Map.delete(state.connections, pid)}
        else
          connection = %{connection | subscriptions: subscriptions}
          %{state | connections: Map.put(state.connections, pid, connection)}
        end
    end
  end

  defp build_dashboard_snapshot(app_id, state) do
    subscriptions =
      Enum.reduce(state.connections, %{}, fn {pid, connection}, acc ->
        Enum.reduce(connection.subscriptions, acc, fn
          {^app_id, channel}, channel_subscribers ->
            Map.update(channel_subscribers, channel, MapSet.new([pid]), &MapSet.put(&1, pid))

          {_other_app_id, _channel}, channel_subscribers ->
            channel_subscribers
        end)
      end)

    presence =
      @table
      |> :ets.tab2list()
      |> Enum.reduce(%{}, fn
        {{^app_id, channel, user_id}, user_info, socket_ids}, members ->
          member = %{
            user_id: user_id,
            user_info: user_info,
            socket_count: MapSet.size(socket_ids)
          }

          Map.update(members, channel, [member], &[member | &1])

        _record, members ->
          members
      end)

    channels =
      subscriptions
      |> Enum.map(fn {channel, pids} ->
        type = channel_type(channel)
        members = Map.get(presence, channel, []) |> Enum.sort_by(& &1.user_id)
        unique_user_count = length(members)

        %{
          name: channel,
          type: type,
          subscription_count:
            if(type == :presence, do: unique_user_count, else: MapSet.size(pids)),
          socket_count: MapSet.size(pids),
          user_count: if(type == :presence, do: unique_user_count, else: nil),
          users: if(type == :presence, do: members, else: [])
        }
      end)
      |> Enum.sort_by(& &1.name)

    %{
      app_id: app_id,
      channel_count: length(channels),
      subscription_count: Enum.reduce(channels, 0, &(&1.subscription_count + &2)),
      channels: channels
    }
  end

  defp channel_type("presence-" <> _), do: :presence
  defp channel_type("private-" <> _), do: :private
  defp channel_type(_channel), do: :public

  defp snapshot(app_id, channel) do
    members = :ets.match_object(@table, {{app_id, channel, :_}, :_, :_})

    hash =
      Map.new(members, fn {{^app_id, ^channel, user_id}, user_info, _socket_ids} ->
        {user_id, user_info}
      end)

    ids = Map.keys(hash)
    %{ids: ids, hash: hash, count: length(ids)}
  end

  defp broadcast_member({app_id, channel, user_id}, action, user_info, excluded_pid, state) do
    payload =
      Jason.encode!(%{
        event: "broadcastex_internal:member_#{action}",
        channel: channel,
        data: %{user_id: user_id, user_info: user_info}
      })

    Enum.each(state.connections, fn
      {^excluded_pid, _connection} ->
        :ok

      {pid, connection} ->
        if MapSet.member?(connection.subscriptions, {app_id, channel}) do
          send(pid, {:broadcast, payload})
        end
    end)
  end
end
