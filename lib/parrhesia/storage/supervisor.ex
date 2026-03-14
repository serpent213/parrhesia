defmodule Parrhesia.Storage.Supervisor do
  @moduledoc """
  Supervision entrypoint for storage adapter processes.
  """

  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Parrhesia.Storage.Adapters.Postgres.ModerationCache,
       name: Parrhesia.Storage.Adapters.Postgres.ModerationCache},
      Parrhesia.Repo
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
