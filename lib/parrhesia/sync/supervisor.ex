defmodule Parrhesia.Sync.Supervisor do
  @moduledoc """
  Supervision entrypoint for sync control-plane processes.
  """

  use Supervisor

  def start_link(init_arg \\ []) do
    name = Keyword.get(init_arg, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, init_arg, name: name)
  end

  @impl true
  def init(init_arg) do
    worker_registry = Keyword.get(init_arg, :worker_registry, Parrhesia.Sync.WorkerRegistry)
    worker_supervisor = Keyword.get(init_arg, :worker_supervisor, Parrhesia.Sync.WorkerSupervisor)
    manager_name = Keyword.get(init_arg, :manager, Parrhesia.API.Sync.Manager)

    children = [
      {Registry, keys: :unique, name: worker_registry},
      {DynamicSupervisor, strategy: :one_for_one, name: worker_supervisor},
      {Parrhesia.API.Sync.Manager,
       manager_opts(init_arg, manager_name, worker_registry, worker_supervisor)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp manager_opts(init_arg, manager_name, worker_registry, worker_supervisor) do
    [
      name: manager_name,
      worker_registry: worker_registry,
      worker_supervisor: worker_supervisor
    ] ++
      Keyword.take(init_arg, [
        :path,
        :start_workers?,
        :transport_module,
        :relay_info_opts,
        :transport_opts
      ])
  end
end
