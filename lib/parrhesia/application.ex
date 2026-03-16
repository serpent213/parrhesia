defmodule Parrhesia.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Parrhesia.Telemetry,
      Parrhesia.Config,
      Parrhesia.Storage.Supervisor,
      Parrhesia.Subscriptions.Supervisor,
      Parrhesia.Auth.Supervisor,
      Parrhesia.Sync.Supervisor,
      Parrhesia.Policy.Supervisor,
      Parrhesia.Web.Endpoint,
      Parrhesia.Tasks.Supervisor
    ]

    opts = [strategy: :one_for_one, name: Parrhesia.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
