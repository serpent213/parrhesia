defmodule Parrhesia.Storage.Supervisor do
  @moduledoc """
  Supervision entrypoint for storage adapter processes.
  """

  use Supervisor

  alias Parrhesia.PostgresRepos

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children =
      memory_store_children() ++ moderation_cache_children() ++ PostgresRepos.started_repos()

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp memory_store_children do
    case Application.get_env(:parrhesia, :storage, [])[:backend] do
      :memory -> [Parrhesia.Storage.Adapters.Memory.Store]
      _other -> []
    end
  end

  defp moderation_cache_children do
    if PostgresRepos.postgres_enabled?() and
         Application.get_env(:parrhesia, :moderation_cache_enabled, true) do
      [
        {Parrhesia.Storage.Adapters.Postgres.ModerationCache,
         name: Parrhesia.Storage.Adapters.Postgres.ModerationCache}
      ]
    else
      []
    end
  end
end
