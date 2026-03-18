defmodule Parrhesia.Runtime do
  @moduledoc """
  Top-level Parrhesia supervisor.

  In normal standalone use, the `:parrhesia` application starts this supervisor automatically.
  Host applications can also embed it directly under their own supervision tree:

      children = [
        {Parrhesia.Runtime, name: Parrhesia.Supervisor}
      ]

  Parrhesia currently assumes a single runtime per BEAM node and uses globally registered
  process names for core services.
  """

  use Supervisor

  @doc """
  Starts the Parrhesia runtime supervisor.

  Accepts a `:name` option (defaults to `Parrhesia.Supervisor`).
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, Parrhesia.Supervisor)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    Supervisor.init(children(), strategy: :one_for_one)
  end

  @doc """
  Returns the list of child specifications started by the runtime supervisor.
  """
  def children do
    [
      Parrhesia.Telemetry,
      Parrhesia.ConnectionStats,
      Parrhesia.Config,
      Parrhesia.Web.EventIngestLimiter,
      Parrhesia.Web.IPEventIngestLimiter,
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
