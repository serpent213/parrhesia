defmodule Parrhesia.Web.Endpoint do
  @moduledoc """
  Supervision entrypoint for configured ingress listeners.
  """

  use Supervisor

  alias Parrhesia.Web.Listener

  def start_link(_init_arg \\ []) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    children =
      Listener.all()
      |> Enum.map(fn listener ->
        %{
          id: {:listener, listener.id},
          start: {Bandit, :start_link, [Listener.bandit_options(listener)]}
        }
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
