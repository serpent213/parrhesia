defmodule Parrhesia.Protocol.EventValidator do
  @moduledoc """
  Strict NIP-01 event validation helpers.
  """

  @required_fields ~w[id pubkey created_at kind tags content sig]
  @max_kind 65_535
  @default_max_event_future_skew_seconds 900

  @type error_reason ::
          :invalid_shape
          | :invalid_id
          | :invalid_pubkey
          | :invalid_created_at
          | :created_at_too_far_in_future
          | :invalid_kind
          | :invalid_tags
          | :invalid_content
          | :invalid_sig
          | :invalid_id_hash

  @spec validate(map()) :: :ok | {:error, error_reason()}
  def validate(event) when is_map(event) do
    with :ok <- validate_required_fields(event),
         :ok <- validate_id_shape(event["id"]),
         :ok <- validate_pubkey(event["pubkey"]),
         :ok <- validate_created_at(event["created_at"]),
         :ok <- validate_kind(event["kind"]),
         :ok <- validate_tags(event["tags"]),
         :ok <- validate_content(event["content"]),
         :ok <- validate_sig(event["sig"]) do
      validate_id_hash(event)
    end
  end

  def validate(_event), do: {:error, :invalid_shape}

  @spec compute_id(map()) :: String.t()
  def compute_id(event) do
    [
      0,
      event["pubkey"],
      event["created_at"],
      event["kind"],
      event["tags"],
      event["content"]
    ]
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @error_messages %{
    invalid_shape:
      "invalid: event must include id, pubkey, created_at, kind, tags, content, and sig",
    invalid_id: "invalid: id must be 32-byte lowercase hex",
    invalid_pubkey: "invalid: pubkey must be 32-byte lowercase hex",
    invalid_created_at: "invalid: created_at must be a non-negative integer unix timestamp",
    created_at_too_far_in_future:
      "invalid: event creation date is too far off from the current time",
    invalid_kind: "invalid: kind must be an integer between 0 and 65535",
    invalid_tags: "invalid: tags must be an array of non-empty string arrays",
    invalid_content: "invalid: content must be a string",
    invalid_sig: "invalid: sig must be 64-byte lowercase hex",
    invalid_id_hash: "invalid: event id does not match serialized event"
  }

  @spec error_message(error_reason()) :: String.t()
  def error_message(reason), do: Map.fetch!(@error_messages, reason)

  defp validate_required_fields(event) do
    if Enum.all?(@required_fields, &Map.has_key?(event, &1)) do
      :ok
    else
      {:error, :invalid_shape}
    end
  end

  defp validate_id_shape(id) when is_binary(id) do
    if lowercase_hex?(id, 32), do: :ok, else: {:error, :invalid_id}
  end

  defp validate_id_shape(_id), do: {:error, :invalid_id}

  defp validate_pubkey(pubkey) when is_binary(pubkey) do
    if lowercase_hex?(pubkey, 32), do: :ok, else: {:error, :invalid_pubkey}
  end

  defp validate_pubkey(_pubkey), do: {:error, :invalid_pubkey}

  defp validate_created_at(created_at) when is_integer(created_at) and created_at >= 0 do
    now = System.system_time(:second)
    max_future_skew = max_event_future_skew_seconds()

    if created_at <= now + max_future_skew do
      :ok
    else
      {:error, :created_at_too_far_in_future}
    end
  end

  defp validate_created_at(_created_at), do: {:error, :invalid_created_at}

  defp validate_kind(kind) when is_integer(kind) and kind >= 0 and kind <= @max_kind, do: :ok
  defp validate_kind(_kind), do: {:error, :invalid_kind}

  defp validate_tags(tags) when is_list(tags) do
    if Enum.all?(tags, &valid_tag?/1) do
      :ok
    else
      {:error, :invalid_tags}
    end
  end

  defp validate_tags(_tags), do: {:error, :invalid_tags}

  defp validate_content(content) when is_binary(content), do: :ok
  defp validate_content(_content), do: {:error, :invalid_content}

  defp validate_sig(sig) when is_binary(sig) do
    if lowercase_hex?(sig, 64), do: :ok, else: {:error, :invalid_sig}
  end

  defp validate_sig(_sig), do: {:error, :invalid_sig}

  defp validate_id_hash(event) do
    if event["id"] == compute_id(event) do
      :ok
    else
      {:error, :invalid_id_hash}
    end
  end

  defp valid_tag?(tag) when is_list(tag) do
    tag != [] and Enum.all?(tag, &is_binary/1)
  end

  defp valid_tag?(_tag), do: false

  defp lowercase_hex?(value, bytes) do
    byte_size(value) == bytes * 2 and
      match?({:ok, _decoded}, Base.decode16(value, case: :lower))
  end

  defp max_event_future_skew_seconds do
    :parrhesia
    |> Application.get_env(:limits, [])
    |> Keyword.get(:max_event_future_skew_seconds, @default_max_event_future_skew_seconds)
  end
end
