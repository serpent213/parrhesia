defmodule Parrhesia.Web.Connection do
  @moduledoc """
  Per-connection websocket process state and message handling.
  """

  @behaviour WebSock

  alias Parrhesia.Protocol
  alias Parrhesia.Protocol.Filter
  alias Parrhesia.Subscriptions.Index

  @default_max_subscriptions_per_connection 32

  defstruct subscriptions: %{},
            authenticated_pubkeys: MapSet.new(),
            max_subscriptions_per_connection: @default_max_subscriptions_per_connection,
            subscription_index: Index

  @type subscription :: %{
          filters: [map()],
          eose_sent?: boolean()
        }

  @type t :: %__MODULE__{
          subscriptions: %{String.t() => subscription()},
          authenticated_pubkeys: MapSet.t(String.t()),
          max_subscriptions_per_connection: pos_integer(),
          subscription_index: GenServer.server() | nil
        }

  @impl true
  def init(opts) do
    state = %__MODULE__{
      max_subscriptions_per_connection: max_subscriptions_per_connection(opts),
      subscription_index: subscription_index(opts)
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
        next_state = drop_subscription(state, subscription_id)
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
end
