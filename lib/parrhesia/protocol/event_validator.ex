defmodule Parrhesia.Protocol.EventValidator do
  @moduledoc """
  Strict NIP-01 event validation helpers.
  """

  @required_fields ~w[id pubkey created_at kind tags content sig]
  @max_kind 65_535
  @default_max_event_future_skew_seconds 900
  @supported_mls_ciphersuites MapSet.new(~w[0x0001 0x0002 0x0003 0x0004 0x0005 0x0006 0x0007])
  @required_mls_extensions MapSet.new(["0xf2ee", "0x000a"])
  @supported_keypackage_ref_sizes [32, 48, 64]

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
          | :invalid_marmot_keypackage_content
          | :missing_marmot_encoding_tag
          | :invalid_marmot_encoding_tag
          | :missing_marmot_protocol_version_tag
          | :invalid_marmot_protocol_version_tag
          | :missing_marmot_ciphersuite_tag
          | :invalid_marmot_ciphersuite_tag
          | :missing_marmot_extensions_tag
          | :invalid_marmot_extensions_tag
          | :missing_marmot_relays_tag
          | :invalid_marmot_relays_tag
          | :missing_marmot_keypackage_ref_tag
          | :invalid_marmot_keypackage_ref_tag
          | :missing_marmot_relay_tag
          | :invalid_marmot_relay_tag
          | :invalid_marmot_direct_welcome_event
          | :invalid_giftwrap_content
          | :missing_giftwrap_recipient_tag
          | :invalid_giftwrap_recipient_tag
          | :missing_marmot_group_tag
          | :invalid_marmot_group_tag
          | :invalid_marmot_group_content

  @spec validate(map()) :: :ok | {:error, error_reason()}
  def validate(event) when is_map(event) do
    with :ok <- validate_required_fields(event),
         :ok <- validate_id_shape(event["id"]),
         :ok <- validate_pubkey(event["pubkey"]),
         :ok <- validate_created_at(event["created_at"]),
         :ok <- validate_kind(event["kind"]),
         :ok <- validate_tags(event["tags"]),
         :ok <- validate_content(event["content"]),
         :ok <- validate_sig(event["sig"]),
         :ok <- validate_id_hash(event) do
      validate_kind_specific(event)
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
    |> JSON.encode!()
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
    invalid_id_hash: "invalid: event id does not match serialized event",
    invalid_marmot_keypackage_content: "invalid: kind 443 content must be non-empty base64",
    missing_marmot_encoding_tag: "invalid: kind 443 must include [\"encoding\", \"base64\"]",
    invalid_marmot_encoding_tag: "invalid: kind 443 must include [\"encoding\", \"base64\"]",
    missing_marmot_protocol_version_tag:
      "invalid: kind 443 must include [\"mls_protocol_version\", \"1.0\"]",
    invalid_marmot_protocol_version_tag:
      "invalid: kind 443 must include [\"mls_protocol_version\", \"1.0\"]",
    missing_marmot_ciphersuite_tag:
      "invalid: kind 443 must include a supported [\"mls_ciphersuite\", \"0x....\"]",
    invalid_marmot_ciphersuite_tag:
      "invalid: kind 443 must include a supported [\"mls_ciphersuite\", \"0x....\"]",
    missing_marmot_extensions_tag:
      "invalid: kind 443 must include [\"mls_extensions\", ...] with 0xf2ee and 0x000a",
    invalid_marmot_extensions_tag:
      "invalid: kind 443 must include [\"mls_extensions\", ...] with 0xf2ee and 0x000a",
    missing_marmot_relays_tag: "invalid: kind 443 must include [\"relays\", <ws/wss url>, ...]",
    invalid_marmot_relays_tag: "invalid: kind 443 must include [\"relays\", <ws/wss url>, ...]",
    missing_marmot_keypackage_ref_tag:
      "invalid: kind 443 must include [\"i\", <hex keypackage ref>]",
    invalid_marmot_keypackage_ref_tag:
      "invalid: kind 443 must include [\"i\", <hex keypackage ref>]",
    missing_marmot_relay_tag:
      "invalid: kind 10051 must include at least one [\"relay\", <ws/wss url>] tag",
    invalid_marmot_relay_tag:
      "invalid: kind 10051 must include at least one [\"relay\", <ws/wss url>] tag",
    invalid_marmot_direct_welcome_event:
      "invalid: kind 444 welcome events must be wrapped in kind 1059 and remain unsigned",
    invalid_giftwrap_content: "invalid: kind 1059 content must be a non-empty encrypted payload",
    missing_giftwrap_recipient_tag:
      "invalid: kind 1059 must include at least one recipient p tag",
    invalid_giftwrap_recipient_tag:
      "invalid: kind 1059 recipient p tags must contain lowercase hex pubkeys",
    missing_marmot_group_tag: "invalid: kind 445 must include at least one h tag with a group id",
    invalid_marmot_group_tag:
      "invalid: kind 445 h tags must contain 32-byte lowercase hex group ids",
    invalid_marmot_group_content: "invalid: kind 445 content must be non-empty base64"
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

  defp validate_kind_specific(%{"kind" => 443} = event),
    do: validate_marmot_keypackage_event(event)

  defp validate_kind_specific(%{"kind" => 10_051} = event),
    do: validate_marmot_keypackage_relay_list(event)

  defp validate_kind_specific(%{"kind" => 445} = event),
    do: validate_marmot_group_event(event)

  defp validate_kind_specific(%{"kind" => 444}),
    do: {:error, :invalid_marmot_direct_welcome_event}

  defp validate_kind_specific(%{"kind" => 1059} = event),
    do: validate_giftwrap_event(event)

  defp validate_kind_specific(_event), do: :ok

  defp validate_marmot_keypackage_event(event) do
    tags = Map.get(event, "tags", [])

    with :ok <- validate_non_empty_base64_content(event),
         {:ok, ["encoding", "base64"]} <-
           fetch_single_tag(tags, "encoding", :missing_marmot_encoding_tag),
         :ok <-
           validate_single_string_tag(
             tags,
             "mls_protocol_version",
             "1.0",
             :missing_marmot_protocol_version_tag,
             :invalid_marmot_protocol_version_tag
           ),
         :ok <-
           validate_single_string_tag_with_predicate(
             tags,
             "mls_ciphersuite",
             :missing_marmot_ciphersuite_tag,
             :invalid_marmot_ciphersuite_tag,
             &supported_mls_ciphersuite?/1
           ),
         :ok <- validate_mls_extensions_tag(tags),
         :ok <-
           validate_relays_tag(
             tags,
             "relays",
             :missing_marmot_relays_tag,
             :invalid_marmot_relays_tag
           ),
         :ok <- validate_keypackage_ref_tag(tags) do
      :ok
    else
      {:ok, _other_tag} -> {:error, :invalid_marmot_encoding_tag}
      {:error, _reason} = error -> error
    end
  end

  defp validate_marmot_keypackage_relay_list(event) do
    tags = Map.get(event, "tags", [])

    relay_tags = Enum.filter(tags, &match_tag_name?(&1, "relay"))

    cond do
      relay_tags == [] ->
        {:error, :missing_marmot_relay_tag}

      Enum.all?(relay_tags, &valid_single_relay_tag?/1) ->
        :ok

      true ->
        {:error, :invalid_marmot_relay_tag}
    end
  end

  defp validate_marmot_group_event(event) do
    tags = Map.get(event, "tags", [])

    with :ok <- validate_non_empty_base64_content(event, :invalid_marmot_group_content) do
      validate_marmot_group_tags(tags)
    end
  end

  defp validate_giftwrap_event(event) do
    tags = Map.get(event, "tags", [])

    with :ok <- validate_non_empty_content(event, :invalid_giftwrap_content) do
      validate_giftwrap_recipient_tags(tags)
    end
  end

  defp validate_non_empty_base64_content(event),
    do: validate_non_empty_base64_content(event, :invalid_marmot_keypackage_content)

  defp validate_non_empty_base64_content(event, error_reason) do
    case Base.decode64(Map.get(event, "content", "")) do
      {:ok, decoded} when byte_size(decoded) > 0 -> :ok
      _other -> {:error, error_reason}
    end
  end

  defp validate_non_empty_content(event, error_reason) do
    case Map.get(event, "content", "") do
      content when is_binary(content) and content != "" -> :ok
      _other -> {:error, error_reason}
    end
  end

  defp validate_marmot_group_tags(tags) do
    group_tags = Enum.filter(tags, &match_tag_name?(&1, "h"))

    cond do
      group_tags == [] ->
        {:error, :missing_marmot_group_tag}

      Enum.all?(group_tags, &valid_marmot_group_tag?/1) ->
        :ok

      true ->
        {:error, :invalid_marmot_group_tag}
    end
  end

  defp validate_giftwrap_recipient_tags(tags) do
    recipient_tags = Enum.filter(tags, &match_tag_name?(&1, "p"))

    cond do
      recipient_tags == [] ->
        {:error, :missing_giftwrap_recipient_tag}

      Enum.all?(recipient_tags, &valid_giftwrap_recipient_tag?/1) ->
        :ok

      true ->
        {:error, :invalid_giftwrap_recipient_tag}
    end
  end

  defp validate_single_string_tag(tags, tag_name, expected_value, missing_error, invalid_error) do
    validate_single_string_tag_with_predicate(
      tags,
      tag_name,
      missing_error,
      invalid_error,
      &(&1 == expected_value)
    )
  end

  defp validate_single_string_tag_with_predicate(
         tags,
         tag_name,
         missing_error,
         invalid_error,
         predicate
       )
       when is_function(predicate, 1) do
    case fetch_single_tag(tags, tag_name, missing_error) do
      {:ok, [^tag_name, value]} ->
        if predicate.(value) do
          :ok
        else
          {:error, invalid_error}
        end

      {:ok, _invalid_tag_shape} ->
        {:error, invalid_error}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_mls_extensions_tag(tags) do
    with {:ok, ["mls_extensions" | extensions]} <-
           fetch_single_tag(tags, "mls_extensions", :missing_marmot_extensions_tag),
         true <- extensions != [],
         true <- Enum.all?(extensions, &valid_mls_extension_id?/1),
         true <- required_mls_extensions_present?(extensions) do
      :ok
    else
      {:ok, _invalid_tag_shape} -> {:error, :invalid_marmot_extensions_tag}
      false -> {:error, :invalid_marmot_extensions_tag}
      {:error, _reason} = error -> error
    end
  end

  defp validate_relays_tag(tags, tag_name, missing_error, invalid_error) do
    with {:ok, [^tag_name | relay_urls]} <- fetch_single_tag(tags, tag_name, missing_error),
         true <- relay_urls != [],
         true <- Enum.all?(relay_urls, &valid_websocket_url?/1) do
      :ok
    else
      {:ok, _invalid_tag_shape} -> {:error, invalid_error}
      false -> {:error, invalid_error}
      {:error, _reason} = error -> error
    end
  end

  defp validate_keypackage_ref_tag(tags) do
    with {:ok, ["i", keypackage_ref]} <-
           fetch_single_tag(tags, "i", :missing_marmot_keypackage_ref_tag),
         true <- valid_keypackage_ref?(keypackage_ref) do
      :ok
    else
      {:ok, _invalid_tag_shape} -> {:error, :invalid_marmot_keypackage_ref_tag}
      false -> {:error, :invalid_marmot_keypackage_ref_tag}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_single_tag(tags, tag_name, missing_error) do
    case Enum.filter(tags, &match_tag_name?(&1, tag_name)) do
      [tag] -> {:ok, tag}
      [] -> {:error, missing_error}
      _duplicates -> {:error, missing_error}
    end
  end

  defp match_tag_name?([tag_name | _rest], expected_tag_name) when is_binary(tag_name),
    do: tag_name == expected_tag_name

  defp match_tag_name?(_tag, _expected_tag_name), do: false

  defp supported_mls_ciphersuite?(value) when is_binary(value) do
    value
    |> String.downcase()
    |> then(&MapSet.member?(@supported_mls_ciphersuites, &1))
  end

  defp supported_mls_ciphersuite?(_value), do: false

  defp valid_mls_extension_id?(value) when is_binary(value) do
    String.match?(value, ~r/^0x[0-9a-fA-F]{4}$/)
  end

  defp valid_mls_extension_id?(_value), do: false

  defp required_mls_extensions_present?(extensions) do
    normalized = MapSet.new(Enum.map(extensions, &String.downcase/1))
    MapSet.subset?(@required_mls_extensions, normalized)
  end

  defp valid_single_relay_tag?(["relay", relay_url]), do: valid_websocket_url?(relay_url)
  defp valid_single_relay_tag?(_tag), do: false

  defp valid_marmot_group_tag?(["h", group_id | _rest]), do: lowercase_hex?(group_id, 32)
  defp valid_marmot_group_tag?(_tag), do: false

  defp valid_giftwrap_recipient_tag?(["p", recipient_pubkey | _rest]),
    do: lowercase_hex?(recipient_pubkey, 32)

  defp valid_giftwrap_recipient_tag?(_tag), do: false

  defp valid_websocket_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["ws", "wss"] and is_binary(host) and host != "" ->
        true

      _other ->
        false
    end
  end

  defp valid_websocket_url?(_url), do: false

  defp valid_keypackage_ref?(value) when is_binary(value) do
    Enum.any?(@supported_keypackage_ref_sizes, &lowercase_hex?(value, &1))
  end

  defp valid_keypackage_ref?(_value), do: false

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
