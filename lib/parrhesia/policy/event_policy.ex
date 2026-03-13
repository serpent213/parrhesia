defmodule Parrhesia.Policy.EventPolicy do
  @moduledoc """
  Write/read policy checks for relay operations.
  """

  alias Parrhesia.Storage

  @type policy_error ::
          :auth_required
          | :restricted_giftwrap
          | :marmot_group_h_tag_required
          | :marmot_group_h_values_exceeded
          | :marmot_group_filter_window_too_wide
          | :media_metadata_tags_exceeded
          | :media_metadata_tag_value_too_large
          | :media_metadata_url_too_long
          | :media_metadata_invalid_url
          | :media_metadata_invalid_hash
          | :media_metadata_invalid_mime
          | :media_metadata_mime_not_allowed
          | :media_metadata_unsupported_version
          | :protected_event_requires_auth
          | :protected_event_pubkey_mismatch
          | :pow_below_minimum
          | :pubkey_banned
          | :event_banned
          | :mls_disabled

  @spec authorize_read([map()], MapSet.t(String.t())) :: :ok | {:error, policy_error()}
  def authorize_read(filters, authenticated_pubkeys) when is_list(filters) do
    auth_required? = config_bool([:policies, :auth_required_for_reads], false)

    cond do
      auth_required? and MapSet.size(authenticated_pubkeys) == 0 ->
        {:error, :auth_required}

      giftwrap_restricted?(filters, authenticated_pubkeys) ->
        {:error, :restricted_giftwrap}

      true ->
        enforce_marmot_group_read_guardrails(filters)
    end
  end

  @spec authorize_write(map(), MapSet.t(String.t())) :: :ok | {:error, policy_error()}
  def authorize_write(event, authenticated_pubkeys) when is_map(event) do
    checks = [
      fn -> maybe_require_auth_for_write(authenticated_pubkeys) end,
      fn -> reject_if_pubkey_banned(event) end,
      fn -> reject_if_event_banned(event) end,
      fn -> enforce_pow(event) end,
      fn -> enforce_protected_event(event, authenticated_pubkeys) end,
      fn -> enforce_media_metadata_policy(event) end,
      fn -> enforce_mls_feature_flag(event) end
    ]

    Enum.reduce_while(checks, :ok, fn check, :ok ->
      case check.() do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec error_message(policy_error()) :: String.t()
  def error_message(:auth_required), do: "auth-required: authentication required"

  def error_message(:restricted_giftwrap),
    do: "restricted: giftwrap access requires recipient authentication"

  def error_message(:marmot_group_h_tag_required),
    do: "restricted: kind 445 queries must include a #h tag"

  def error_message(:marmot_group_h_values_exceeded),
    do: "rate-limited: kind 445 queries exceed maximum #h values"

  def error_message(:marmot_group_filter_window_too_wide),
    do: "rate-limited: kind 445 query window exceeds configured maximum"

  def error_message(:media_metadata_tags_exceeded),
    do: "rate-limited: too many media metadata tags in event"

  def error_message(:media_metadata_tag_value_too_large),
    do: "invalid: media metadata field value exceeds configured limit"

  def error_message(:media_metadata_url_too_long),
    do: "invalid: media metadata url exceeds configured limit"

  def error_message(:media_metadata_invalid_url),
    do: "invalid: media metadata url must be a valid http/https URL"

  def error_message(:media_metadata_invalid_hash),
    do: "invalid: media metadata x field must be 32-byte lowercase hex"

  def error_message(:media_metadata_invalid_mime),
    do: "invalid: media metadata mime type is invalid"

  def error_message(:media_metadata_mime_not_allowed),
    do: "blocked: media metadata mime type is not allowed"

  def error_message(:media_metadata_unsupported_version),
    do: "blocked: media metadata version is not supported"

  def error_message(:protected_event_requires_auth),
    do: "auth-required: protected events require authenticated pubkey"

  def error_message(:protected_event_pubkey_mismatch),
    do: "restricted: protected event pubkey does not match authenticated pubkey"

  def error_message(:pow_below_minimum), do: "pow: minimum proof-of-work difficulty not met"
  def error_message(:pubkey_banned), do: "blocked: pubkey is banned"
  def error_message(:event_banned), do: "blocked: event is banned"
  def error_message(:mls_disabled), do: "blocked: mls feature flag is disabled"

  defp maybe_require_auth_for_write(authenticated_pubkeys) do
    if config_bool([:policies, :auth_required_for_writes], false) and
         MapSet.size(authenticated_pubkeys) == 0 do
      {:error, :auth_required}
    else
      :ok
    end
  end

  defp giftwrap_restricted?(filters, authenticated_pubkeys) do
    if MapSet.size(authenticated_pubkeys) == 0 do
      any_filter_targets_giftwrap?(filters)
    else
      not giftwrap_filters_include_authenticated_recipient?(filters, authenticated_pubkeys)
    end
  end

  defp any_filter_targets_giftwrap?(filters) do
    Enum.any?(filters, fn filter ->
      case Map.get(filter, "kinds") do
        kinds when is_list(kinds) -> 1059 in kinds
        _other -> false
      end
    end)
  end

  defp giftwrap_filters_include_authenticated_recipient?(filters, authenticated_pubkeys) do
    Enum.all?(filters, fn filter ->
      if targets_giftwrap?(filter) do
        recipients = Map.get(filter, "#p") || []
        recipients != [] and Enum.any?(recipients, &MapSet.member?(authenticated_pubkeys, &1))
      else
        true
      end
    end)
  end

  defp targets_giftwrap?(filter) do
    case Map.get(filter, "kinds") do
      kinds when is_list(kinds) -> 1059 in kinds
      _other -> false
    end
  end

  defp enforce_marmot_group_read_guardrails(filters) do
    cond do
      marmot_group_h_tag_required_violation?(filters) ->
        {:error, :marmot_group_h_tag_required}

      marmot_group_h_values_exceeded?(filters) ->
        {:error, :marmot_group_h_values_exceeded}

      marmot_group_query_window_too_wide?(filters) ->
        {:error, :marmot_group_filter_window_too_wide}

      true ->
        :ok
    end
  end

  defp marmot_group_h_tag_required_violation?(filters) do
    config_bool([:policies, :marmot_require_h_for_group_queries], true) and
      Enum.any?(filters, fn filter ->
        targets_marmot_group_events?(filter) and not valid_h_tag_values?(Map.get(filter, "#h"))
      end)
  end

  defp marmot_group_h_values_exceeded?(filters) do
    max_h_values = config_int([:policies, :marmot_group_max_h_values_per_filter], 32)

    max_h_values > 0 and
      Enum.any?(filters, fn filter ->
        targets_marmot_group_events?(filter) and h_tag_values_count(filter) > max_h_values
      end)
  end

  defp marmot_group_query_window_too_wide?(filters) do
    max_window = config_int([:policies, :marmot_group_max_query_window_seconds], 2_592_000)

    max_window > 0 and
      Enum.any?(filters, fn filter ->
        if targets_marmot_group_events?(filter) do
          query_window_exceeds?(filter, max_window)
        else
          false
        end
      end)
  end

  defp targets_marmot_group_events?(filter) do
    case Map.get(filter, "kinds") do
      kinds when is_list(kinds) -> 445 in kinds
      _other -> false
    end
  end

  defp h_tag_values_count(filter) do
    case Map.get(filter, "#h") do
      values when is_list(values) -> length(values)
      _other -> 0
    end
  end

  defp valid_h_tag_values?(values) when is_list(values) do
    values != [] and Enum.all?(values, &lowercase_hex?(&1, 32))
  end

  defp valid_h_tag_values?(_values), do: false

  defp query_window_exceeds?(filter, max_window) do
    case {Map.get(filter, "since"), Map.get(filter, "until")} do
      {since, until}
      when is_integer(since) and since >= 0 and is_integer(until) and until >= 0 and
             until >= since ->
        until - since > max_window

      _other ->
        false
    end
  end

  defp lowercase_hex?(value, bytes) when is_binary(value) do
    byte_size(value) == bytes * 2 and
      match?({:ok, _decoded}, Base.decode16(value, case: :lower))
  end

  defp lowercase_hex?(_value, _bytes), do: false

  defp enforce_media_metadata_policy(event) do
    imeta_tags =
      event
      |> Map.get("tags", [])
      |> Enum.filter(&imeta_tag?/1)

    max_imeta_tags = config_int([:policies, :marmot_media_max_imeta_tags_per_event], 8)

    if max_imeta_tags > 0 and length(imeta_tags) > max_imeta_tags do
      {:error, :media_metadata_tags_exceeded}
    else
      validate_imeta_tags(imeta_tags)
    end
  end

  defp imeta_tag?(["imeta" | _rest]), do: true
  defp imeta_tag?(_tag), do: false

  defp validate_imeta_tags(imeta_tags) do
    Enum.reduce_while(imeta_tags, :ok, fn tag, :ok ->
      with {:ok, fields} <- parse_imeta_tag(tag),
           :ok <- validate_imeta_fields(fields) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_imeta_tag(["imeta" | fields]) when is_list(fields) do
    if fields != [] and rem(length(fields), 2) == 0 do
      parsed_fields =
        fields
        |> Enum.chunk_every(2)
        |> Enum.reduce(%{}, fn [key, value], acc -> Map.put(acc, key, value) end)

      {:ok, parsed_fields}
    else
      {:error, :media_metadata_tag_value_too_large}
    end
  end

  defp parse_imeta_tag(_tag), do: {:error, :media_metadata_tag_value_too_large}

  defp validate_imeta_fields(fields) do
    with :ok <- validate_imeta_value_sizes(fields),
         :ok <- validate_imeta_url(fields),
         :ok <- validate_imeta_hash(fields),
         :ok <- validate_imeta_mime(fields) do
      validate_imeta_version(fields)
    end
  end

  defp validate_imeta_value_sizes(fields) do
    max_value_bytes = config_int([:policies, :marmot_media_max_field_value_bytes], 1024)

    if max_value_bytes <= 0 or Enum.all?(Map.values(fields), &(byte_size(&1) <= max_value_bytes)) do
      :ok
    else
      {:error, :media_metadata_tag_value_too_large}
    end
  end

  defp validate_imeta_url(fields) do
    case Map.get(fields, "url") do
      nil ->
        :ok

      url ->
        max_url_bytes = config_int([:policies, :marmot_media_max_url_bytes], 2048)

        cond do
          max_url_bytes > 0 and byte_size(url) > max_url_bytes ->
            {:error, :media_metadata_url_too_long}

          valid_http_url?(url) ->
            :ok

          true ->
            {:error, :media_metadata_invalid_url}
        end
    end
  end

  defp validate_imeta_hash(fields) do
    case Map.get(fields, "x") do
      nil ->
        :ok

      hash ->
        if lowercase_hex?(hash, 32) do
          :ok
        else
          {:error, :media_metadata_invalid_hash}
        end
    end
  end

  defp validate_imeta_mime(fields) do
    case Map.get(fields, "m") do
      nil ->
        :ok

      mime_type ->
        allowed_prefixes = config_list([:policies, :marmot_media_allowed_mime_prefixes], [])

        cond do
          not valid_mime_type?(mime_type) ->
            {:error, :media_metadata_invalid_mime}

          allowed_prefixes == [] ->
            :ok

          Enum.any?(allowed_prefixes, &String.starts_with?(mime_type, &1)) ->
            :ok

          true ->
            {:error, :media_metadata_mime_not_allowed}
        end
    end
  end

  defp validate_imeta_version(fields) do
    case Map.get(fields, "v") do
      nil ->
        :ok

      "mip04-v2" ->
        :ok

      "mip04-v1" ->
        if config_bool([:policies, :marmot_media_reject_mip04_v1], true) do
          {:error, :media_metadata_unsupported_version}
        else
          :ok
        end

      _other ->
        {:error, :media_metadata_unsupported_version}
    end
  end

  defp valid_http_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _other ->
        false
    end
  end

  defp valid_http_url?(_url), do: false

  defp valid_mime_type?(mime_type) when is_binary(mime_type) do
    String.match?(mime_type, ~r/^[a-z0-9!#$&^_.+\-]+\/[a-z0-9!#$&^_.+\-]+$/)
  end

  defp valid_mime_type?(_mime_type), do: false

  defp reject_if_pubkey_banned(event) do
    with pubkey when is_binary(pubkey) <- Map.get(event, "pubkey"),
         {:ok, true} <- Storage.moderation().pubkey_banned?(%{}, pubkey) do
      {:error, :pubkey_banned}
    else
      {:ok, false} -> :ok
      _other -> :ok
    end
  end

  defp reject_if_event_banned(event) do
    with event_id when is_binary(event_id) <- Map.get(event, "id"),
         {:ok, true} <- Storage.moderation().event_banned?(%{}, event_id) do
      {:error, :event_banned}
    else
      {:ok, false} -> :ok
      _other -> :ok
    end
  end

  defp enforce_pow(event) do
    min_difficulty = config_int([:policies, :min_pow_difficulty], 0)

    if min_difficulty <= 0 do
      :ok
    else
      difficulty = event_pow_difficulty(event)

      if difficulty >= min_difficulty do
        :ok
      else
        {:error, :pow_below_minimum}
      end
    end
  end

  defp event_pow_difficulty(event) do
    event
    |> Map.get("id", "")
    |> String.downcase()
    |> String.graphemes()
    |> Enum.reduce_while(0, fn
      "0", acc -> {:cont, acc + 4}
      hex, acc -> {:halt, acc + leading_zero_bits(hex)}
    end)
  end

  defp leading_zero_bits("1"), do: 3
  defp leading_zero_bits("2"), do: 2
  defp leading_zero_bits("3"), do: 2
  defp leading_zero_bits("4"), do: 1
  defp leading_zero_bits("5"), do: 1
  defp leading_zero_bits("6"), do: 1
  defp leading_zero_bits("7"), do: 1
  defp leading_zero_bits("8"), do: 0
  defp leading_zero_bits("9"), do: 0
  defp leading_zero_bits("a"), do: 0
  defp leading_zero_bits("b"), do: 0
  defp leading_zero_bits("c"), do: 0
  defp leading_zero_bits("d"), do: 0
  defp leading_zero_bits("e"), do: 0
  defp leading_zero_bits("f"), do: 0
  defp leading_zero_bits(_other), do: 0

  defp enforce_protected_event(event, authenticated_pubkeys) do
    protected? =
      event
      |> Map.get("tags", [])
      |> Enum.any?(fn
        ["-" | _rest] -> true
        _tag -> false
      end)

    if protected? do
      pubkey = Map.get(event, "pubkey")

      cond do
        MapSet.size(authenticated_pubkeys) == 0 -> {:error, :protected_event_requires_auth}
        MapSet.member?(authenticated_pubkeys, pubkey) -> :ok
        true -> {:error, :protected_event_pubkey_mismatch}
      end
    else
      :ok
    end
  end

  defp enforce_mls_feature_flag(event) do
    if event["kind"] in [443, 445, 10_051] and not config_bool([:features, :nip_ee_mls], false) do
      {:error, :mls_disabled}
    else
      :ok
    end
  end

  defp config_bool([scope, key], default) do
    case Application.get_env(:parrhesia, scope, []) |> Keyword.get(key, default) do
      true -> true
      false -> false
      _other -> default
    end
  end

  defp config_int([scope, key], default) do
    case Application.get_env(:parrhesia, scope, []) |> Keyword.get(key, default) do
      value when is_integer(value) -> value
      _other -> default
    end
  end

  defp config_list([scope, key], default) do
    case Application.get_env(:parrhesia, scope, []) |> Keyword.get(key, default) do
      value when is_list(value) ->
        if Enum.all?(value, &is_binary/1), do: value, else: default

      _other ->
        default
    end
  end
end
