defmodule Parrhesia.API.Stream.Subscription do
  @moduledoc false

  use GenServer, restart: :temporary

  alias Parrhesia.Protocol.Filter
  alias Parrhesia.Subscriptions.Index

  defstruct [
    :ref,
    :subscriber,
    :subscriber_monitor_ref,
    :subscription_id,
    :filters,
    ready?: false,
    buffered_events: []
  ]

  @type t :: %__MODULE__{
          ref: reference(),
          subscriber: pid(),
          subscriber_monitor_ref: reference(),
          subscription_id: String.t(),
          filters: [map()],
          ready?: boolean(),
          buffered_events: [map()]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    ref = Keyword.fetch!(opts, :ref)

    GenServer.start_link(__MODULE__, opts, name: via_tuple(ref))
  end

  @spec deliver_initial(GenServer.server(), [map()]) :: :ok | {:error, term()}
  def deliver_initial(server, initial_events) when is_list(initial_events) do
    GenServer.call(server, {:deliver_initial, initial_events})
  end

  @impl true
  def init(opts) do
    with {:ok, subscriber} <- fetch_subscriber(opts),
         {:ok, subscription_id} <- fetch_subscription_id(opts),
         {:ok, filters} <- fetch_filters(opts),
         :ok <-
           maybe_upsert_index_subscription(subscription_index(opts), subscription_id, filters) do
      monitor_ref = Process.monitor(subscriber)

      state = %__MODULE__{
        ref: Keyword.fetch!(opts, :ref),
        subscriber: subscriber,
        subscriber_monitor_ref: monitor_ref,
        subscription_id: subscription_id,
        filters: filters,
        ready?: false,
        buffered_events: []
      }

      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:deliver_initial, initial_events}, _from, %__MODULE__{} = state) do
    send_initial_events(state, initial_events)

    Enum.each(Enum.reverse(state.buffered_events), fn event ->
      send(state.subscriber, {:parrhesia, :event, state.ref, state.subscription_id, event})
    end)

    {:reply, :ok, %__MODULE__{state | ready?: true, buffered_events: []}}
  end

  @impl true
  def handle_info({:fanout_event, subscription_id, event}, %__MODULE__{} = state)
      when is_binary(subscription_id) and is_map(event) do
    handle_fanout_event(state, subscription_id, event)
  end

  def handle_info({:DOWN, monitor_ref, :process, subscriber, _reason}, %__MODULE__{} = state)
      when monitor_ref == state.subscriber_monitor_ref and subscriber == state.subscriber do
    {:stop, :normal, state}
  end

  def handle_info(_message, %__MODULE__{} = state), do: {:noreply, state}

  @impl true
  def terminate(reason, %__MODULE__{} = state) do
    :ok = maybe_remove_index_subscription(state.subscription_id)

    if reason not in [:normal, :shutdown] do
      send(state.subscriber, {:parrhesia, :closed, state.ref, state.subscription_id, reason})
    end

    :ok
  end

  defp send_initial_events(state, events) do
    Enum.each(events, fn event ->
      send(state.subscriber, {:parrhesia, :event, state.ref, state.subscription_id, event})
    end)

    send(state.subscriber, {:parrhesia, :eose, state.ref, state.subscription_id})
  end

  defp via_tuple(ref), do: {:via, Registry, {Parrhesia.API.Stream.Registry, ref}}

  defp fetch_subscriber(opts) do
    case Keyword.get(opts, :subscriber) do
      subscriber when is_pid(subscriber) -> {:ok, subscriber}
      _other -> {:error, :invalid_subscriber}
    end
  end

  defp fetch_subscription_id(opts) do
    case Keyword.get(opts, :subscription_id) do
      subscription_id when is_binary(subscription_id) -> {:ok, subscription_id}
      _other -> {:error, :invalid_subscription_id}
    end
  end

  defp fetch_filters(opts) do
    case Keyword.get(opts, :filters) do
      filters when is_list(filters) -> {:ok, filters}
      _other -> {:error, :invalid_filters}
    end
  end

  defp subscription_index(opts) do
    case Keyword.get(opts, :subscription_index, Index) do
      subscription_index when is_pid(subscription_index) or is_atom(subscription_index) ->
        subscription_index

      _other ->
        nil
    end
  end

  defp maybe_upsert_index_subscription(nil, _subscription_id, _filters),
    do: {:error, :subscription_index_unavailable}

  defp maybe_upsert_index_subscription(subscription_index, subscription_id, filters) do
    case Index.upsert(subscription_index, self(), subscription_id, filters) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _reason -> {:error, :subscription_index_unavailable}
  end

  defp maybe_remove_index_subscription(subscription_id) do
    :ok = Index.remove(Index, self(), subscription_id)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp handle_fanout_event(%__MODULE__{} = state, subscription_id, event) do
    cond do
      subscription_id != state.subscription_id ->
        {:noreply, state}

      not Filter.matches_any?(event, state.filters) ->
        {:noreply, state}

      state.ready? ->
        send(state.subscriber, {:parrhesia, :event, state.ref, state.subscription_id, event})
        {:noreply, state}

      true ->
        buffered_events = [event | state.buffered_events]
        {:noreply, %__MODULE__{state | buffered_events: buffered_events}}
    end
  end
end
