defmodule Parrhesia.Web.MetricsEndpoint do
  @moduledoc """
  Optional dedicated HTTP listener for Prometheus metrics scraping.
  """

  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(init_arg) do
    options = bandit_options(init_arg)

    children =
      if Keyword.get(options, :enabled, false) do
        [{Bandit, Keyword.delete(options, :enabled)}]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp bandit_options(overrides) do
    configured = Application.get_env(:parrhesia, __MODULE__, [])

    configured
    |> Keyword.merge(overrides)
    |> Keyword.put_new(:scheme, :http)
    |> Keyword.put_new(:plug, Parrhesia.Web.MetricsRouter)
  end
end
