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
         :ok <- clear_pem_cache(),
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
    listener_ids =
      supervisor
      |> Supervisor.which_children()
      |> Enum.flat_map(fn
        {{:listener, listener_id}, _pid, _type, _modules} -> [listener_id]
        _other -> []
      end)

    with :ok <- terminate_listeners(supervisor, listener_ids),
         :ok <- clear_pem_cache() do
      restart_listeners(supervisor, listener_ids)
    end
  end

  defp terminate_listeners(_supervisor, []), do: :ok

  defp terminate_listeners(supervisor, [listener_id | rest]) do
    case Supervisor.terminate_child(supervisor, {:listener, listener_id}) do
      :ok -> terminate_listeners(supervisor, rest)
      {:error, _reason} = error -> error
    end
  end

  defp restart_listeners(_supervisor, []), do: :ok

  defp restart_listeners(supervisor, [listener_id | rest]) do
    case Supervisor.restart_child(supervisor, {:listener, listener_id}) do
      {:ok, _pid} -> restart_listeners(supervisor, rest)
      {:error, _reason} = error -> error
    end
  end

  # OTP's ssl module caches PEM file contents by filename. When cert/key
  # files are replaced on disk, the cache must be cleared so the restarted
  # listener reads the updated files.
  defp clear_pem_cache do
    :ssl.clear_pem_cache()
    :ok
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
