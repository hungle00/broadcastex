defmodule Broadcastex.AppStore do
  use GenServer

  @table :broadcastex_apps
  @attributes [:app_id, :key, :app]

  # API Public
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_app_by_key(key) do
    with {:ok, records} <-
           transact(fn -> :mnesia.index_read(@table, key, :key) end) do
      case records do
        [{@table, _app_id, ^key, app}] -> {:ok, app}
        [] -> {:error, :not_found}
        _ -> {:error, :ambiguous_key}
      end
    end
  end

  def get_app_by_id(app_id) do
    with {:ok, records} <-
           transact(fn -> :mnesia.read(@table, app_id, :read) end) do
      case records do
        [{@table, ^app_id, _key, app}] -> {:ok, app}
        [] -> {:error, :not_found}
      end
    end
  end

  def register_app(app_id, key, secret) do
    app = %{app_id: app_id, key: key, secret: secret}

    with {:ok, :ok} <-
           transact(fn -> :mnesia.write({@table, app_id, key, app}) end) do
      :ok
    end
  end

  # GenServer Callbacks
  @impl true
  def init(_opts) do
    with :ok <- ensure_mnesia_started(),
         :ok <- ensure_table() do
      {:ok, %{}}
    else
      {:error, reason} -> {:stop, {:mnesia_initialization_failed, reason}}
    end
  end

  defp ensure_mnesia_started do
    case :mnesia.system_info(:is_running) do
      :yes ->
        ensure_disk_schema()

      :no ->
        with :ok <- ensure_schema(),
             {:ok, _started_apps} <- Application.ensure_all_started(:mnesia) do
          ensure_disk_schema()
        end

      state ->
        {:error, {:unexpected_mnesia_state, state}}
    end
  end

  defp ensure_disk_schema do
    case :mnesia.table_info(:schema, :storage_type) do
      :disc_copies ->
        :ok

      :ram_copies ->
        case :mnesia.change_table_copy_type(:schema, node(), :disc_copies) do
          {:atomic, :ok} -> :ok
          {:aborted, reason} -> {:error, reason}
        end

      storage_type ->
        {:error, {:unsupported_schema_storage_type, storage_type}}
    end
  end

  defp ensure_schema do
    case :mnesia.create_schema([node()]) do
      :ok ->
        :ok

      {:error, {existing_node, {:already_exists, existing_node}}}
      when existing_node == node() ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_table do
    case :mnesia.create_table(@table,
           attributes: @attributes,
           disc_copies: [node()],
           index: [:key]
         ) do
      {:atomic, :ok} -> wait_for_table()
      {:aborted, {:already_exists, @table}} -> wait_for_table()
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp wait_for_table do
    case :mnesia.wait_for_tables([@table], 5_000) do
      :ok -> :ok
      {:timeout, tables} -> {:error, {:table_wait_timeout, tables}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transact(fun) do
    case :mnesia.transaction(fun) do
      {:atomic, result} -> {:ok, result}
      {:aborted, reason} -> {:error, reason}
    end
  end
end
