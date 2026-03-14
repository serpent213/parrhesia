defmodule Parrhesia.Tasks.Supervisor do
  @moduledoc """
  Supervision entrypoint for background maintenance jobs.
  """

  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = expiration_children() ++ partition_retention_children()

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp expiration_children do
    if Application.get_env(:parrhesia, :enable_expiration_worker, true) do
      [{Parrhesia.Tasks.ExpirationWorker, name: Parrhesia.Tasks.ExpirationWorker}]
    else
      []
    end
  end

  defp partition_retention_children do
    [
      {Parrhesia.Tasks.PartitionRetentionWorker, name: Parrhesia.Tasks.PartitionRetentionWorker}
    ]
  end
end
