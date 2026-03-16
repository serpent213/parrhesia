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
          | {:auth, event()}
          | {:count, String.t(), [filter()], map()}
          | {:neg_open, String.t(), filter(), binary()}
          | {:neg_msg, String.t(), binary()}
          | {:neg_close, String.t()}

  @type relay_message ::
          {:notice, String.t()}
          | {:ok, String.t(), boolean(), String.t()}
          | {:closed, String.t(), String.t()}
          | {:eose, String.t()}
          | {:event, String.t(), event()}
          | {:auth, String.t()}
          | {:count, String.t(), map()}
          | {:neg_msg, String.t(), String.t()}
          | {:neg_err, String.t(), String.t()}

  @type decode_error ::
          :invalid_json
          | :invalid_message
          | :invalid_event
          | :invalid_subscription_id
          | :invalid_filters
          | :invalid_auth
          | :invalid_count
          | :invalid_negentropy

  @count_options_keys MapSet.new(["hll", "approximate"])

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
    |> JSON.encode!()
  end

  @spec decode_error_notice(decode_error()) :: String.t()
  def decode_error_notice(reason) do
    case reason do
      :invalid_json -> "invalid: malformed JSON"
      :invalid_message -> "invalid: unsupported message shape"
      :invalid_event -> "invalid: invalid EVENT shape"
      :invalid_subscription_id -> "invalid: invalid subscription id"
      :invalid_filters -> "invalid: invalid filters"
      :invalid_auth -> "invalid: invalid AUTH message"
      :invalid_count -> "invalid: invalid COUNT message"
      :invalid_negentropy -> "invalid: invalid NEG message"
    end
  end

  defp decode_json(payload) do
    case JSON.decode(payload) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp decode_message(["EVENT", event]) when is_map(event), do: {:ok, {:event, event}}
  defp decode_message(["EVENT", _event]), do: {:error, :invalid_event}

  defp decode_message(["REQ", subscription_id | filters]) when is_binary(subscription_id) do
    decode_req_like_message(:req, subscription_id, filters)
  end

  defp decode_message(["REQ", _subscription_id | _filters]),
    do: {:error, :invalid_subscription_id}

  defp decode_message(["COUNT", subscription_id | filters_or_options])
       when is_binary(subscription_id) do
    with {:ok, filters, options} <- split_count_parts(filters_or_options),
         {:ok, {:req, ^subscription_id, parsed_filters}} <-
           decode_req_like_message(:req, subscription_id, filters) do
      {:ok, {:count, subscription_id, parsed_filters, options}}
    else
      _error -> {:error, :invalid_count}
    end
  end

  defp decode_message(["COUNT", _subscription_id | _filters_or_options]),
    do: {:error, :invalid_count}

  defp decode_message(["CLOSE", subscription_id]) when is_binary(subscription_id) do
    if valid_subscription_id?(subscription_id) do
      {:ok, {:close, subscription_id}}
    else
      {:error, :invalid_subscription_id}
    end
  end

  defp decode_message(["CLOSE", _subscription_id]), do: {:error, :invalid_subscription_id}

  defp decode_message(["AUTH", auth_event]) when is_map(auth_event),
    do: {:ok, {:auth, auth_event}}

  defp decode_message(["AUTH", _invalid]), do: {:error, :invalid_auth}

  defp decode_message(["NEG-OPEN", subscription_id, filter, initial_message])
       when is_binary(subscription_id) and is_map(filter) and is_binary(initial_message) do
    with true <- valid_subscription_id?(subscription_id),
         {:ok, decoded_message} <- decode_negentropy_hex(initial_message) do
      {:ok, {:neg_open, subscription_id, filter, decoded_message}}
    else
      false -> {:error, :invalid_subscription_id}
      {:error, _reason} -> {:error, :invalid_negentropy}
    end
  end

  defp decode_message(["NEG-MSG", subscription_id, payload])
       when is_binary(subscription_id) and is_binary(payload) do
    with true <- valid_subscription_id?(subscription_id),
         {:ok, decoded_payload} <- decode_negentropy_hex(payload) do
      {:ok, {:neg_msg, subscription_id, decoded_payload}}
    else
      false -> {:error, :invalid_subscription_id}
      {:error, _reason} -> {:error, :invalid_negentropy}
    end
  end

  defp decode_message(["NEG-CLOSE", subscription_id]) when is_binary(subscription_id) do
    if valid_subscription_id?(subscription_id) do
      {:ok, {:neg_close, subscription_id}}
    else
      {:error, :invalid_subscription_id}
    end
  end

  defp decode_message([type | _rest]) when type in ["NEG-OPEN", "NEG-MSG", "NEG-CLOSE"],
    do: {:error, :invalid_negentropy}

  defp decode_message(_other), do: {:error, :invalid_message}

  defp decode_req_like_message(_kind, subscription_id, filters) do
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

  defp split_count_parts(parts) when is_list(parts) do
    if parts == [] do
      {:error, :missing_filters}
    else
      split_count_parts_with_optional_options(parts)
    end
  end

  defp split_count_parts(_parts), do: {:error, :invalid_parts}

  defp split_count_parts_with_optional_options(parts) do
    case List.last(parts) do
      options when is_map(options) ->
        maybe_extract_count_options(parts, options)

      _other ->
        {:ok, parts, %{}}
    end
  end

  defp maybe_extract_count_options(parts, options) do
    if count_options_map?(options) and length(parts) > 1 do
      filters = Enum.drop(parts, -1)
      {:ok, filters, options}
    else
      {:ok, parts, %{}}
    end
  end

  defp count_options_map?(map) do
    map
    |> Map.keys()
    |> Enum.all?(&MapSet.member?(@count_options_keys, &1))
  end

  defp relay_frame({:notice, message}), do: ["NOTICE", message]
  defp relay_frame({:ok, event_id, accepted, message}), do: ["OK", event_id, accepted, message]
  defp relay_frame({:closed, subscription_id, message}), do: ["CLOSED", subscription_id, message]
  defp relay_frame({:eose, subscription_id}), do: ["EOSE", subscription_id]
  defp relay_frame({:event, subscription_id, event}), do: ["EVENT", subscription_id, event]
  defp relay_frame({:auth, challenge}), do: ["AUTH", challenge]
  defp relay_frame({:count, subscription_id, payload}), do: ["COUNT", subscription_id, payload]

  defp relay_frame({:neg_msg, subscription_id, payload}),
    do: ["NEG-MSG", subscription_id, payload]

  defp relay_frame({:neg_err, subscription_id, reason}),
    do: ["NEG-ERR", subscription_id, reason]

  defp valid_subscription_id?(subscription_id) do
    subscription_id != "" and String.length(subscription_id) <= 64
  end

  defp decode_negentropy_hex(payload) when is_binary(payload) and payload != "" do
    case Base.decode16(payload, case: :mixed) do
      {:ok, decoded} when decoded != <<>> -> {:ok, decoded}
      _other -> {:error, :invalid_negentropy}
    end
  end

  defp decode_negentropy_hex(_payload), do: {:error, :invalid_negentropy}
end
