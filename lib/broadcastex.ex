defmodule Broadcastex do
  @moduledoc """
  Documentation for `Broadcastex`.
  """

  @doc """
  Hello world.

  ## Examples

      iex> Broadcastex.hello()
      :world

  """
  def hello do
    :world
  end

  def channel_topic(app_id, channel), do: "broadcastex:#{app_id}:#{channel}"
end
