defmodule Parrhesia.Web.Connection do
  @moduledoc """
  Per-connection websocket process state and message handling.
  """

  @behaviour WebSock

  alias Parrhesia.Protocol
  alias Parrhesia.Protocol.Filter
  alias Parrhesia.Subscriptions.Index

  @default_max_subscriptions_per_connection 32
  @default_max_outbound_queue 256
  @default_outbound_drain_batch_size 64
  @default_outbound_overflow_strategy :close
  @drain_outbound_queue :drain_outbound_queue

  defstruct subscriptions: %{},
            authenticated_pubkeys: MapSet.new(),
            max_subscriptions_per_connection: @default_max_subscriptions_per_connection,
            subscription_index: Index,
            outbound_queue: :queue.new(),
            outbound_queue_size: 0,
            max_outbound_queue: @default_max_outbound_queue,
            outbound_overflow_strategy: @default_outbound_overflow_strategy,
            outbound_drain_batch_size: @default_outbound_drain_batch_size,
            drain_scheduled?: false

  @type overflow_strategy :: :close | :drop_oldest | :drop_newest

  @type subscription :: %{
          filters: [map()],
          eose_sent?: boolean()
        }

  @type t :: %__MODULE__{
          subscriptions: %{String.t() => subscription()},
          authenticated_pubkeys: MapSet.t(String.t()),
          max_subscriptions_per_connection: pos_integer(),
          subscription_index: GenServer.server() | nil,
          outbound_queue: :queue.queue({String.t(), map()}),
          outbound_queue_size: non_neg_integer(),
          max_outbound_queue: pos_integer(),
          outbound_overflow_strategy: overflow_strategy(),
          outbound_drain_batch_size: pos_integer(),
          drain_scheduled?: boolean()
        }

  @impl true
  def init(opts) do
    state = %__MODULE__{
      max_subscriptions_per_connection: max_subscriptions_per_connection(opts),
      subscription_index: subscription_index(opts),
      max_outbound_queue: max_outbound_queue(opts),
      outbound_overflow_strategy: outbound_overflow_strategy(opts),
      outbound_drain_batch_size: outbound_drain_batch_size(opts)
    }

    {:ok, state}
  end

  @impl true
  def handle_in({payload, [opcode: :text]}, %__MODULE__{} = state) do
    case Protocol.decode_client(payload) do
      {:ok, {:event, event}} ->
        event_id = Map.get(event, "id", "")

        response =
          case Protocol.validate_event(event) do
            :ok ->
              Protocol.encode_relay({:ok, event_id, false, "error: EVENT ingest not implemented"})

            {:error, message} ->
              Protocol.encode_relay({:ok, event_id, false, message})
          end

        {:push, {:text, response}, state}

      {:ok, {:req, subscription_id, filters}} ->
        handle_req(state, subscription_id, filters)

      {:ok, {:close, subscription_id}} ->
        next_state =
          state
          |> drop_subscription(subscription_id)
          |> drop_queued_subscription_events(subscription_id)

        :ok = maybe_remove_index_subscription(next_state, subscription_id)

        response =
          Protocol.encode_relay({:closed, subscription_id, "error: subscription closed"})

        {:push, {:text, response}, next_state}

      {:error, reason} ->
        response = Protocol.encode_relay({:notice, Protocol.decode_error_notice(reason)})
        {:push, {:text, response}, state}
    end
  end

  @impl true
  def handle_in({_payload, [opcode: :binary]}, %__MODULE__{} = state) do
    response =
      Protocol.encode_relay({:notice, "invalid: binary websocket frames are not supported"})

    {:push, {:text, response}, state}
  end

  @impl true
  def handle_info({:fanout_event, subscription_id, event}, %__MODULE__{} = state)
      when is_binary(subscription_id) and is_map(event) do
    handle_fanout_events(state, [{subscription_id, event}])
  end

  def handle_info({:fanout_events, fanout_events}, %__MODULE__{} = state)
      when is_list(fanout_events) do
    handle_fanout_events(state, fanout_events)
  end

  def handle_info(@drain_outbound_queue, %__MODULE__{} = state) do
    {frames, next_state} = drain_outbound_frames(state)

    if frames == [] do
      {:ok, next_state}
    else
      {:push, frames, next_state}
    end
  end

  def handle_info(_message, %__MODULE__{} = state) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, %__MODULE__{} = state) do
    :ok = maybe_remove_index_owner(state)
    :ok
  end

  defp handle_req(%__MODULE__{} = state, subscription_id, filters) do
    with :ok <- Filter.validate_filters(filters),
         {:ok, next_state} <- upsert_subscription(state, subscription_id, filters) do
      :ok = maybe_upsert_index_subscription(next_state, subscription_id, filters)

      response = Protocol.encode_relay({:eose, subscription_id})
      {:push, {:text, response}, next_state}
    else
      {:error, :subscription_limit_reached} ->
        response =
          Protocol.encode_relay({
            :closed,
            subscription_id,
            "rate-limited: maximum subscriptions per connection exceeded"
          })

        {:push, {:text, response}, state}

      {:error, reason} ->
        response = Protocol.encode_relay({:closed, subscription_id, Filter.error_message(reason)})
        {:push, {:text, response}, state}
    end
  end

  defp handle_fanout_events(%__MODULE__{} = state, fanout_events) do
    case enqueue_fanout_events(state, fanout_events) do
      {:ok, next_state} ->
        {:ok, maybe_schedule_drain(next_state)}

      {:close, next_state} ->
        close_with_outbound_overflow(next_state)
    end
  end

  defp close_with_outbound_overflow(state) do
    message = "rate-limited: outbound queue overflow"
    notice = Protocol.encode_relay({:notice, message})

    {:stop, :normal, {1008, message}, [{:text, notice}], state}
  end

  defp enqueue_fanout_events(state, fanout_events) do
    Enum.reduce_while(fanout_events, {:ok, state}, fn
      {subscription_id, event}, {:ok, acc} when is_binary(subscription_id) and is_map(event) ->
        case maybe_enqueue_fanout_event(acc, subscription_id, event) do
          {:ok, next_acc} -> {:cont, {:ok, next_acc}}
          {:close, next_acc} -> {:halt, {:close, next_acc}}
        end

      _invalid_event, {:ok, acc} ->
        {:cont, {:ok, acc}}
    end)
  end

  defp maybe_enqueue_fanout_event(state, subscription_id, event) do
    if subscription_matches?(state, subscription_id, event) do
      enqueue_outbound(state, {subscription_id, event})
    else
      {:ok, state}
    end
  end

  defp subscription_matches?(%__MODULE__{} = state, subscription_id, event) do
    case Map.get(state.subscriptions, subscription_id) do
      nil -> false
      %{filters: filters} -> Filter.matches_any?(event, filters)
    end
  end

  defp enqueue_outbound(
         %__MODULE__{outbound_queue_size: queue_size, max_outbound_queue: max_outbound_queue} =
           state,
         queue_entry
       )
       when queue_size < max_outbound_queue do
    {:ok,
     %__MODULE__{
       state
       | outbound_queue: :queue.in(queue_entry, state.outbound_queue),
         outbound_queue_size: queue_size + 1
     }}
  end

  defp enqueue_outbound(
         %__MODULE__{outbound_overflow_strategy: :drop_newest} = state,
         _queue_entry
       ),
       do: {:ok, state}

  defp enqueue_outbound(
         %__MODULE__{outbound_overflow_strategy: :drop_oldest} = state,
         queue_entry
       ) do
    {next_queue, next_size} =
      drop_oldest_and_enqueue(state.outbound_queue, state.outbound_queue_size, queue_entry)

    {:ok, %__MODULE__{state | outbound_queue: next_queue, outbound_queue_size: next_size}}
  end

  defp enqueue_outbound(%__MODULE__{outbound_overflow_strategy: :close} = state, _queue_entry),
    do: {:close, state}

  defp drop_oldest_and_enqueue(queue, queue_size, queue_entry) when queue_size > 0 do
    {_dropped, truncated_queue} = :queue.out(queue)
    {:queue.in(queue_entry, truncated_queue), queue_size}
  end

  defp drop_oldest_and_enqueue(queue, queue_size, queue_entry) do
    {:queue.in(queue_entry, queue), queue_size + 1}
  end

  defp drain_outbound_frames(%__MODULE__{} = state) do
    {frames, next_queue, remaining_size} =
      pop_frames(
        state.outbound_queue,
        state.outbound_queue_size,
        state.outbound_drain_batch_size,
        []
      )

    next_state =
      %__MODULE__{
        state
        | outbound_queue: next_queue,
          outbound_queue_size: remaining_size,
          drain_scheduled?: false
      }
      |> maybe_schedule_drain()

    {Enum.reverse(frames), next_state}
  end

  defp pop_frames(queue, queue_size, _remaining_batch, acc) when queue_size == 0,
    do: {acc, queue, queue_size}

  defp pop_frames(queue, queue_size, remaining_batch, acc) when remaining_batch <= 0,
    do: {acc, queue, queue_size}

  defp pop_frames(queue, queue_size, remaining_batch, acc) do
    case :queue.out(queue) do
      {{:value, {subscription_id, event}}, next_queue} ->
        frame = {:text, Protocol.encode_relay({:event, subscription_id, event})}
        pop_frames(next_queue, queue_size - 1, remaining_batch - 1, [frame | acc])

      {:empty, _same_queue} ->
        {acc, :queue.new(), 0}
    end
  end

  defp maybe_schedule_drain(%__MODULE__{drain_scheduled?: true} = state), do: state

  defp maybe_schedule_drain(%__MODULE__{outbound_queue_size: 0} = state), do: state

  defp maybe_schedule_drain(%__MODULE__{} = state) do
    send(self(), @drain_outbound_queue)
    %__MODULE__{state | drain_scheduled?: true}
  end

  defp upsert_subscription(%__MODULE__{} = state, subscription_id, filters) do
    subscription = %{filters: filters, eose_sent?: true}

    cond do
      Map.has_key?(state.subscriptions, subscription_id) ->
        {:ok, put_subscription(state, subscription_id, subscription)}

      map_size(state.subscriptions) < state.max_subscriptions_per_connection ->
        {:ok, put_subscription(state, subscription_id, subscription)}

      true ->
        {:error, :subscription_limit_reached}
    end
  end

  defp put_subscription(%__MODULE__{} = state, subscription_id, subscription) do
    subscriptions = Map.put(state.subscriptions, subscription_id, subscription)
    %__MODULE__{state | subscriptions: subscriptions}
  end

  defp drop_subscription(%__MODULE__{} = state, subscription_id) do
    subscriptions = Map.delete(state.subscriptions, subscription_id)
    %__MODULE__{state | subscriptions: subscriptions}
  end

  defp drop_queued_subscription_events(
         %__MODULE__{outbound_queue_size: 0} = state,
         _subscription_id
       ),
       do: state

  defp drop_queued_subscription_events(%__MODULE__{} = state, subscription_id) do
    filtered_entries =
      state.outbound_queue
      |> :queue.to_list()
      |> Enum.reject(fn
        {^subscription_id, _event} -> true
        _queue_entry -> false
      end)

    %__MODULE__{
      state
      | outbound_queue: :queue.from_list(filtered_entries),
        outbound_queue_size: length(filtered_entries)
    }
  end

  defp maybe_upsert_index_subscription(
         %__MODULE__{subscription_index: nil},
         _subscription_id,
         _filters
       ),
       do: :ok

  defp maybe_upsert_index_subscription(
         %__MODULE__{subscription_index: subscription_index},
         subscription_id,
         filters
       ) do
    case Index.upsert(subscription_index, self(), subscription_id, filters) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp maybe_remove_index_subscription(
         %__MODULE__{subscription_index: nil},
         _subscription_id
       ),
       do: :ok

  defp maybe_remove_index_subscription(
         %__MODULE__{subscription_index: subscription_index},
         subscription_id
       ) do
    :ok = Index.remove(subscription_index, self(), subscription_id)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp maybe_remove_index_owner(%__MODULE__{subscription_index: nil}), do: :ok

  defp maybe_remove_index_owner(%__MODULE__{subscription_index: subscription_index}) do
    :ok = Index.remove_owner(subscription_index, self())
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp subscription_index(opts) when is_list(opts) do
    opts
    |> Keyword.get(:subscription_index, Index)
    |> normalize_subscription_index()
  end

  defp subscription_index(opts) when is_map(opts) do
    opts
    |> Map.get(:subscription_index, Index)
    |> normalize_subscription_index()
  end

  defp subscription_index(_opts), do: Index

  defp normalize_subscription_index(subscription_index)
       when is_pid(subscription_index) or is_atom(subscription_index),
       do: subscription_index

  defp normalize_subscription_index(_subscription_index), do: nil

  defp max_subscriptions_per_connection(opts) when is_list(opts) do
    opts
    |> Keyword.get(:max_subscriptions_per_connection)
    |> normalize_max_subscriptions_per_connection()
  end

  defp max_subscriptions_per_connection(opts) when is_map(opts) do
    opts
    |> Map.get(:max_subscriptions_per_connection)
    |> normalize_max_subscriptions_per_connection()
  end

  defp max_subscriptions_per_connection(_opts), do: configured_max_subscriptions_per_connection()

  defp normalize_max_subscriptions_per_connection(value) when is_integer(value) and value > 0,
    do: value

  defp normalize_max_subscriptions_per_connection(_value),
    do: configured_max_subscriptions_per_connection()

  defp configured_max_subscriptions_per_connection do
    :parrhesia
    |> Application.get_env(:limits, [])
    |> Keyword.get(
      :max_subscriptions_per_connection,
      @default_max_subscriptions_per_connection
    )
  end

  defp max_outbound_queue(opts) when is_list(opts) do
    opts
    |> Keyword.get(:max_outbound_queue)
    |> normalize_max_outbound_queue()
  end

  defp max_outbound_queue(opts) when is_map(opts) do
    opts
    |> Map.get(:max_outbound_queue)
    |> normalize_max_outbound_queue()
  end

  defp max_outbound_queue(_opts), do: configured_max_outbound_queue()

  defp normalize_max_outbound_queue(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_outbound_queue(_value), do: configured_max_outbound_queue()

  defp configured_max_outbound_queue do
    :parrhesia
    |> Application.get_env(:limits, [])
    |> Keyword.get(:max_outbound_queue, @default_max_outbound_queue)
  end

  defp outbound_drain_batch_size(opts) when is_list(opts) do
    opts
    |> Keyword.get(:outbound_drain_batch_size)
    |> normalize_outbound_drain_batch_size()
  end

  defp outbound_drain_batch_size(opts) when is_map(opts) do
    opts
    |> Map.get(:outbound_drain_batch_size)
    |> normalize_outbound_drain_batch_size()
  end

  defp outbound_drain_batch_size(_opts), do: configured_outbound_drain_batch_size()

  defp normalize_outbound_drain_batch_size(value) when is_integer(value) and value > 0,
    do: value

  defp normalize_outbound_drain_batch_size(_value), do: configured_outbound_drain_batch_size()

  defp configured_outbound_drain_batch_size do
    :parrhesia
    |> Application.get_env(:limits, [])
    |> Keyword.get(:outbound_drain_batch_size, @default_outbound_drain_batch_size)
  end

  defp outbound_overflow_strategy(opts) when is_list(opts) do
    opts
    |> Keyword.get(:outbound_overflow_strategy)
    |> normalize_outbound_overflow_strategy()
  end

  defp outbound_overflow_strategy(opts) when is_map(opts) do
    opts
    |> Map.get(:outbound_overflow_strategy)
    |> normalize_outbound_overflow_strategy()
  end

  defp outbound_overflow_strategy(_opts), do: configured_outbound_overflow_strategy()

  defp normalize_outbound_overflow_strategy(:close), do: :close
  defp normalize_outbound_overflow_strategy(:drop_oldest), do: :drop_oldest
  defp normalize_outbound_overflow_strategy(:drop_newest), do: :drop_newest

  defp normalize_outbound_overflow_strategy(_value), do: configured_outbound_overflow_strategy()

  defp configured_outbound_overflow_strategy do
    :parrhesia
    |> Application.get_env(:limits, [])
    |> Keyword.get(:outbound_overflow_strategy, @default_outbound_overflow_strategy)
  end
end
