defmodule Parrhesia.Subscriptions.Supervisor do
  @moduledoc """
  Supervision entrypoint for subscription index and fanout workers.
  """

  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Parrhesia.Subscriptions.Index, name: Parrhesia.Subscriptions.Index}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
