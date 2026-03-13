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
    Supervisor.init([], strategy: :one_for_one)
  end
end
