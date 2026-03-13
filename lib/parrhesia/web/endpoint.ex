defmodule Parrhesia.Web.Endpoint do
  @moduledoc """
  Supervision entrypoint for WS/HTTP ingress.
  """

  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(init_arg) do
    children = [
      {Bandit, bandit_options(init_arg)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp bandit_options(overrides) do
    configured = Application.get_env(:parrhesia, __MODULE__, [])

    configured
    |> Keyword.merge(overrides)
    |> Keyword.put_new(:scheme, :http)
    |> Keyword.put_new(:plug, Parrhesia.Web.Router)
  end
end
