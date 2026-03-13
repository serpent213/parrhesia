defmodule Parrhesia.Web.Connection do
  @moduledoc """
  Per-connection websocket process state and message handling.
  """

  @behaviour WebSock

  alias Parrhesia.Protocol
  alias Parrhesia.Protocol.Filter

  @default_max_subscriptions_per_connection 32

  defstruct subscriptions: %{},
            authenticated_pubkeys: MapSet.new(),
            max_subscriptions_per_connection: @default_max_subscriptions_per_connection

  @type subscription :: %{
          filters: [map()],
          eose_sent?: boolean()
        }

  @type t :: %__MODULE__{
          subscriptions: %{String.t() => subscription()},
          authenticated_pubkeys: MapSet.t(String.t()),
          max_subscriptions_per_connection: pos_integer()
        }

  @impl true
  def init(opts) do
    state = %__MODULE__{max_subscriptions_per_connection: max_subscriptions_per_connection(opts)}
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

  defp handle_req(%__MODULE__{} = state, subscription_id, filters) do
    with :ok <- Filter.validate_filters(filters),
         {:ok, next_state} <- upsert_subscription(state, subscription_id, filters) do
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
