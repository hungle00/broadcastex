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

  def handle_call({:leave, app_id, channel, pid}, _from, state) do
    state =
      case Map.get(state.connections, pid) do
        nil ->
          state

        connection ->
          connection.memberships
          |> Enum.filter(fn {member_app_id, member_channel, _user_id} ->
            member_app_id == app_id and member_channel == channel
          end)
          |> Enum.reduce(state, fn membership, acc ->
            remove_membership(acc, pid, connection.socket_id, membership)
          end)
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.connections, pid) do
      %{ref: ^ref} = connection ->
        state =
          Enum.reduce(connection.memberships, state, fn membership, acc ->
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
        :ets.insert(@table, {membership, user_info, MapSet.new([socket_id])})
        state = add_connection_membership(state, pid, socket_id, membership)
        broadcast_member(membership, "added", user_info, pid, state)
        {:reply, {:ok, snapshot(elem(membership, 0), elem(membership, 1))}, state}

      [{^membership, ^user_info, socket_ids}] ->
        :ets.insert(@table, {membership, user_info, MapSet.put(socket_ids, socket_id)})
        state = add_connection_membership(state, pid, socket_id, membership)
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
        case Enum.find(connection.memberships, fn {member_app_id, member_channel, _member_user_id} ->
               member_app_id == app_id and member_channel == channel
             end) do
          nil -> :ok
          {^app_id, ^channel, ^user_id} -> :ok
          _membership -> {:error, :user_identity_mismatch}
        end
    end
  end

  defp add_connection_membership(state, pid, socket_id, membership) do
    case Map.get(state.connections, pid) do
      nil ->
        ref = Process.monitor(pid)

        connection = %{
          ref: ref,
          socket_id: socket_id,
          memberships: MapSet.new([membership])
        }

        %{state | connections: Map.put(state.connections, pid, connection)}

      connection ->
        connection = %{
          connection
          | memberships: MapSet.put(connection.memberships, membership)
        }

        %{state | connections: Map.put(state.connections, pid, connection)}
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

    update_connection_memberships(state, pid, membership)
  end

  defp update_connection_memberships(state, pid, membership) do
    case Map.get(state.connections, pid) do
      nil ->
        state

      connection ->
        memberships = MapSet.delete(connection.memberships, membership)

        if MapSet.size(memberships) == 0 do
          Process.demonitor(connection.ref, [:flush])
          %{state | connections: Map.delete(state.connections, pid)}
        else
          connection = %{connection | memberships: memberships}
          %{state | connections: Map.put(state.connections, pid, connection)}
        end
    end
  end

  defp snapshot(app_id, channel) do
    members =
      :ets.match_object(@table, {{app_id, channel, :_}, :_, :_})

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
        if Enum.any?(connection.memberships, fn {member_app_id, member_channel, _member_user_id} ->
             member_app_id == app_id and member_channel == channel
           end) do
          send(pid, {:broadcast, payload})
        end
    end)
  end
end
