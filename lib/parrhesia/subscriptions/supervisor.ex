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
    children =
      [
        {Parrhesia.Subscriptions.Index, name: Parrhesia.Subscriptions.Index}
      ] ++
        negentropy_children() ++ [{Parrhesia.Fanout.MultiNode, name: Parrhesia.Fanout.MultiNode}]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp negentropy_children do
    if negentropy_enabled?() do
      [{Parrhesia.Negentropy.Sessions, name: Parrhesia.Negentropy.Sessions}]
    else
      []
    end
  end

  defp negentropy_enabled? do
    :parrhesia
    |> Application.get_env(:features, [])
    |> Keyword.get(:nip_77_negentropy, true)
  end
end
