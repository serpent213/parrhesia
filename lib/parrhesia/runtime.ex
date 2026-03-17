defmodule Parrhesia.Runtime do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, Parrhesia.Supervisor)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    Supervisor.init(children(), strategy: :one_for_one)
  end

  def children do
    [
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
  end
end
