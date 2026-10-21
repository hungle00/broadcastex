defmodule Broadcastex.PresenceManagerTest do
  use ExUnit.Case, async: false

  test "keeps a user present until their last socket disconnects" do
    app_id = "test-app-#{System.unique_integer([:positive])}"
    channel = "presence-test-#{System.unique_integer([:positive])}"
    user_info = %{"name" => "Alice"}

    assert {:ok, %{count: 1, ids: ["observer"]}} =
             Broadcastex.PresenceManager.join(
               app_id,
               channel,
               "observer-socket",
               self(),
               "observer",
               %{}
             )

    on_exit(fn -> Broadcastex.PresenceManager.leave(app_id, channel, self()) end)

    assert {:error, :user_identity_mismatch} =
             Broadcastex.PresenceManager.join(
               app_id,
               channel,
               "observer-socket",
               self(),
               "another-user",
               %{}
             )

    {first_socket, {:ok, first_snapshot}} =
      start_socket(app_id, channel, "socket-1", "user-1", user_info)

    on_exit(fn -> cleanup([first_socket]) end)
    assert first_snapshot.count == 2

    assert_receive {:broadcast, added_payload}

    assert %{
             "event" => "broadcastex_internal:member_added",
             "data" => %{"user_id" => "user-1", "user_info" => %{"name" => "Alice"}}
           } = Jason.decode!(added_payload)

    {second_socket, second_result} =
      start_socket(app_id, channel, "socket-2", "user-1", user_info)

    on_exit(fn -> cleanup([first_socket, second_socket]) end)

    assert {:ok, %{count: 2, ids: ids, hash: %{"user-1" => ^user_info}}} = second_result
    assert "observer" in ids

    refute_receive {:broadcast, _payload}, 100

    Process.exit(first_socket, :kill)
    refute_receive {:broadcast, _payload}, 100

    Process.exit(second_socket, :kill)

    assert_receive {:broadcast, removed_payload}, 1_000

    assert %{
             "event" => "broadcastex_internal:member_removed",
             "data" => %{"user_id" => "user-1", "user_info" => %{"name" => "Alice"}}
           } = Jason.decode!(removed_payload)
  end

  defp start_socket(app_id, channel, socket_id, user_id, user_info) do
    parent = self()

    pid =
      spawn(fn ->
        result =
          Broadcastex.PresenceManager.join(
            app_id,
            channel,
            socket_id,
            self(),
            user_id,
            user_info
          )

        send(parent, {:socket_joined, self(), result})

        receive do
          :wait -> :ok
        end
      end)

    assert_receive {:socket_joined, ^pid, result}
    {pid, result}
  end

  defp cleanup(pids) do
    Enum.each(pids, fn pid ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)
  end
end
