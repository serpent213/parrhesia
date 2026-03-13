defmodule Parrhesia.Web.Connection do
  @moduledoc """
  Per-connection websocket process state and message handling.
  """

  @behaviour WebSock

  alias Parrhesia.Protocol

  defstruct subscriptions: MapSet.new(), authenticated_pubkeys: MapSet.new()

  @type t :: %__MODULE__{
          subscriptions: MapSet.t(String.t()),
          authenticated_pubkeys: MapSet.t(String.t())
        }

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_in({payload, [opcode: :text]}, %__MODULE__{} = state) do
    case Protocol.decode_client(payload) do
      {:ok, {:event, event}} ->
        event_id = Map.get(event, "id", "")

        response =
          Protocol.encode_relay({
            :ok,
            event_id,
            false,
            "error:unsupported: EVENT ingest not implemented"
          })

        {:push, {:text, response}, state}

      {:ok, {:req, subscription_id, _filters}} ->
        next_state = put_subscription(state, subscription_id)
        response = Protocol.encode_relay({:eose, subscription_id})

        {:push, {:text, response}, next_state}

      {:ok, {:close, subscription_id}} ->
        next_state = drop_subscription(state, subscription_id)

        response =
          Protocol.encode_relay({:closed, subscription_id, "closed: subscription closed"})

        {:push, {:text, response}, next_state}

      {:error, reason} ->
        response = Protocol.encode_relay({:notice, Protocol.decode_error_notice(reason)})
        {:push, {:text, response}, state}
    end
  end

  @impl true
  def handle_in({_payload, [opcode: :binary]}, %__MODULE__{} = state) do
    response =
      Protocol.encode_relay({:notice, "error:invalid: binary websocket frames are not supported"})

    {:push, {:text, response}, state}
  end

  @impl true
  def handle_info(_message, %__MODULE__{} = state) do
    {:ok, state}
  end

  defp put_subscription(%__MODULE__{} = state, subscription_id) do
    subscriptions = MapSet.put(state.subscriptions, subscription_id)
    %__MODULE__{state | subscriptions: subscriptions}
  end

  defp drop_subscription(%__MODULE__{} = state, subscription_id) do
    subscriptions = MapSet.delete(state.subscriptions, subscription_id)
    %__MODULE__{state | subscriptions: subscriptions}
  end
end
