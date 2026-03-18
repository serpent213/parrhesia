defmodule Parrhesia.Auth.Supervisor do
  @moduledoc """
  Supervision entrypoint for AUTH challenge/session tracking.
  """

  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Parrhesia.Auth.Challenges, name: Parrhesia.Auth.Challenges},
      {Parrhesia.Auth.Nip98ReplayCache, name: Parrhesia.Auth.Nip98ReplayCache},
      {Parrhesia.API.Identity.Manager, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
