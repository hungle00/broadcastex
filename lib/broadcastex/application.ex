defmodule Broadcastex.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Broadcastex.AppStore,
      {Phoenix.PubSub, name: Broadcastex.PubSub},
      Broadcastex.PresenceManager,
      {Bandit, plug: Broadcastex.Router, port: 4000}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Broadcastex.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
