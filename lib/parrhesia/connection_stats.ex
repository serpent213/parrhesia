defmodule Parrhesia.ConnectionStats do
  @moduledoc false

  use GenServer

  alias Parrhesia.Telemetry

  defstruct connections: %{}, subscriptions: %{}

  @type state :: %__MODULE__{
          connections: %{(atom() | String.t()) => non_neg_integer()},
          subscriptions: %{(atom() | String.t()) => non_neg_integer()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: name)
  end

  @spec connection_open(atom() | String.t()) :: :ok
  def connection_open(listener_id), do: cast({:connection_open, listener_id})

  @spec connection_close(atom() | String.t()) :: :ok
  def connection_close(listener_id), do: cast({:connection_close, listener_id})

  @spec subscriptions_change(atom() | String.t(), integer()) :: :ok
  def subscriptions_change(listener_id, delta) when is_integer(delta) do
    cast({:subscriptions_change, listener_id, delta})
  end

  @impl true
  def init(%__MODULE__{} = state), do: {:ok, state}

  @impl true
  def handle_cast({:connection_open, listener_id}, %__MODULE__{} = state) do
    listener_id = normalize_listener_id(listener_id)
    next_state = %{state | connections: increment(state.connections, listener_id, 1)}
    emit_population(listener_id, next_state)
    {:noreply, next_state}
  end

  def handle_cast({:connection_close, listener_id}, %__MODULE__{} = state) do
    listener_id = normalize_listener_id(listener_id)
    next_state = %{state | connections: increment(state.connections, listener_id, -1)}
    emit_population(listener_id, next_state)
    {:noreply, next_state}
  end

  def handle_cast({:subscriptions_change, listener_id, delta}, %__MODULE__{} = state) do
    listener_id = normalize_listener_id(listener_id)
    next_state = %{state | subscriptions: increment(state.subscriptions, listener_id, delta)}
    emit_population(listener_id, next_state)
    {:noreply, next_state}
  end

  defp cast(message) do
    GenServer.cast(__MODULE__, message)
    :ok
  catch
    :exit, {:noproc, _details} -> :ok
    :exit, {:normal, _details} -> :ok
  end

  defp increment(counts, key, delta) do
    current = Map.get(counts, key, 0)
    Map.put(counts, key, max(current + delta, 0))
  end

  defp emit_population(listener_id, %__MODULE__{} = state) do
    Telemetry.emit(
      [:parrhesia, :listener, :population],
      %{
        connections: Map.get(state.connections, listener_id, 0),
        subscriptions: Map.get(state.subscriptions, listener_id, 0)
      },
      %{listener_id: listener_id}
    )
  end

  defp normalize_listener_id(listener_id) when is_atom(listener_id), do: listener_id
  defp normalize_listener_id(listener_id) when is_binary(listener_id), do: listener_id
  defp normalize_listener_id(_listener_id), do: :unknown
end
