defmodule Parrhesia.Protocol do
  @moduledoc """
  Nostr protocol message decode/encode helpers.
  """

  alias Parrhesia.Protocol.EventValidator

  @type event :: map()
  @type filter :: map()

  @type client_message ::
          {:event, event()}
          | {:req, String.t(), [filter()]}
          | {:close, String.t()}

  @type relay_message ::
          {:notice, String.t()}
          | {:ok, String.t(), boolean(), String.t()}
          | {:closed, String.t(), String.t()}
          | {:eose, String.t()}
          | {:event, String.t(), event()}

  @type decode_error ::
          :invalid_json
          | :invalid_message
          | :invalid_event
          | :invalid_subscription_id
          | :invalid_filters

  @spec decode_client(binary()) :: {:ok, client_message()} | {:error, decode_error()}
  def decode_client(payload) when is_binary(payload) do
    with {:ok, decoded} <- decode_json(payload) do
      decode_message(decoded)
    end
  end

  @spec validate_event(event()) :: :ok | {:error, String.t()}
  def validate_event(event) do
    case EventValidator.validate(event) do
      :ok -> :ok
      {:error, reason} -> {:error, EventValidator.error_message(reason)}
    end
  end

  @spec encode_relay(relay_message()) :: binary()
  def encode_relay(message) do
    message
    |> relay_frame()
    |> Jason.encode!()
  end

  @spec decode_error_notice(decode_error()) :: String.t()
  def decode_error_notice(reason) do
    case reason do
      :invalid_json -> "invalid: malformed JSON"
      :invalid_message -> "invalid: unsupported message shape"
      :invalid_event -> "invalid: invalid EVENT shape"
      :invalid_subscription_id -> "invalid: invalid subscription id"
      :invalid_filters -> "invalid: invalid filters"
    end
  end

  defp decode_json(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp decode_message(["EVENT", event]) when is_map(event), do: {:ok, {:event, event}}
  defp decode_message(["EVENT", _event]), do: {:error, :invalid_event}

  defp decode_message(["REQ", subscription_id | filters]) when is_binary(subscription_id) do
    cond do
      not valid_subscription_id?(subscription_id) ->
        {:error, :invalid_subscription_id}

      filters == [] ->
        {:error, :invalid_filters}

      Enum.all?(filters, &is_map/1) ->
        {:ok, {:req, subscription_id, filters}}

      true ->
        {:error, :invalid_filters}
    end
  end

  defp decode_message(["REQ", _subscription_id | _filters]),
    do: {:error, :invalid_subscription_id}

  defp decode_message(["CLOSE", subscription_id]) when is_binary(subscription_id) do
    if valid_subscription_id?(subscription_id) do
      {:ok, {:close, subscription_id}}
    else
      {:error, :invalid_subscription_id}
    end
  end

  defp decode_message(["CLOSE", _subscription_id]), do: {:error, :invalid_subscription_id}
  defp decode_message(_other), do: {:error, :invalid_message}

  defp relay_frame({:notice, message}), do: ["NOTICE", message]
  defp relay_frame({:ok, event_id, accepted, message}), do: ["OK", event_id, accepted, message]
  defp relay_frame({:closed, subscription_id, message}), do: ["CLOSED", subscription_id, message]
  defp relay_frame({:eose, subscription_id}), do: ["EOSE", subscription_id]
  defp relay_frame({:event, subscription_id, event}), do: ["EVENT", subscription_id, event]

  defp valid_subscription_id?(subscription_id) do
    subscription_id != "" and String.length(subscription_id) <= 64
  end
end
