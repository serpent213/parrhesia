defmodule Parrhesia.Web.Endpoint do
  @moduledoc """
  Supervision entrypoint for configured ingress listeners.
  """

  use Supervisor

  alias Parrhesia.Web.Listener

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    listeners = Keyword.get(opts, :listeners, :configured)
    Supervisor.start_link(__MODULE__, listeners, name: name)
  end

  @spec reload_listener(Supervisor.supervisor(), atom()) :: :ok | {:error, term()}
  def reload_listener(supervisor \\ __MODULE__, listener_id) when is_atom(listener_id) do
    with :ok <- Supervisor.terminate_child(supervisor, {:listener, listener_id}),
         {:ok, _pid} <- Supervisor.restart_child(supervisor, {:listener, listener_id}) do
      :ok
    else
      {:error, :not_found} = error -> error
      {:error, _reason} = error -> error
      other -> other
    end
  end

  @spec reload_all(Supervisor.supervisor()) :: :ok | {:error, term()}
  def reload_all(supervisor \\ __MODULE__) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.filter(fn {id, _pid, _type, _modules} ->
      match?({:listener, _listener_id}, id)
    end)
    |> Enum.reduce_while(:ok, fn {{:listener, listener_id}, _pid, _type, _modules}, :ok ->
      case reload_listener(supervisor, listener_id) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @impl true
  def init(listeners) do
    children =
      listeners(listeners)
      |> Enum.map(fn listener ->
        %{
          id: {:listener, listener.id},
          start: {Bandit, :start_link, [Listener.bandit_options(listener)]}
        }
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp listeners(:configured), do: Listener.all()

  defp listeners(listeners) when is_list(listeners) do
    Enum.map(listeners, fn
      {id, listener} when is_atom(id) and is_map(listener) ->
        Listener.from_opts(listener: Map.put_new(listener, :id, id))

      listener ->
        Listener.from_opts(listener: listener)
    end)
  end

  defp listeners(listeners) when is_map(listeners) do
    listeners
    |> Enum.map(fn {id, listener} -> {id, listener} end)
    |> listeners()
  end
end
