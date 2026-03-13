defmodule Parrhesia.Protocol.Filter do
  @moduledoc """
  NIP-01 filter validation and matching.
  """

  @max_kind 65_535
  @default_max_filters_per_req 16

  @type validation_error ::
          :invalid_filters
          | :empty_filters
          | :too_many_filters
          | :invalid_filter
          | :invalid_filter_key
          | :invalid_ids
          | :invalid_authors
          | :invalid_kinds
          | :invalid_since
          | :invalid_until
          | :invalid_limit
          | :invalid_tag_filter

  @allowed_keys MapSet.new(["ids", "authors", "kinds", "since", "until", "limit"])

  @error_messages %{
    invalid_filters: "invalid: filters must be a non-empty array of objects",
    empty_filters: "invalid: filters must be a non-empty array of objects",
    too_many_filters: "invalid: too many filters in REQ",
    invalid_filter: "invalid: each filter must be an object",
    invalid_filter_key: "invalid: filter contains unknown elements",
    invalid_ids: "invalid: ids must be a non-empty array of 64-char lowercase hex values",
    invalid_authors: "invalid: authors must be a non-empty array of 64-char lowercase hex values",
    invalid_kinds: "invalid: kinds must be a non-empty array of integers between 0 and 65535",
    invalid_since: "invalid: since must be a non-negative integer",
    invalid_until: "invalid: until must be a non-negative integer",
    invalid_limit: "invalid: limit must be a positive integer",
    invalid_tag_filter:
      "invalid: tag filters must use #<single-letter> with non-empty string arrays"
  }

  @spec validate_filters([map()]) :: :ok | {:error, validation_error()}
  def validate_filters(filters) when is_list(filters) do
    cond do
      filters == [] ->
        {:error, :empty_filters}

      length(filters) > max_filters_per_req() ->
        {:error, :too_many_filters}

      true ->
        validate_each_filter(filters)
    end
  end

  def validate_filters(_filters), do: {:error, :invalid_filters}

  defp validate_each_filter(filters) do
    Enum.reduce_while(filters, :ok, fn filter, :ok ->
      case validate_filter(filter) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec validate_filter(map()) :: :ok | {:error, validation_error()}
  def validate_filter(filter) when is_map(filter) do
    with :ok <- validate_filter_keys(filter),
         :ok <- validate_hex_filter(Map.get(filter, "ids"), 32, :invalid_ids),
         :ok <- validate_hex_filter(Map.get(filter, "authors"), 32, :invalid_authors),
         :ok <- validate_kinds(Map.get(filter, "kinds")),
         :ok <- validate_since(Map.get(filter, "since")),
         :ok <- validate_until(Map.get(filter, "until")),
         :ok <- validate_limit(Map.get(filter, "limit")) do
      validate_tag_filters(filter)
    end
  end

  def validate_filter(_filter), do: {:error, :invalid_filter}

  @spec matches_any?(map(), [map()]) :: boolean()
  def matches_any?(event, filters) when is_map(event) and is_list(filters) do
    Enum.any?(filters, &matches_filter?(event, &1))
  end

  def matches_any?(_event, _filters), do: false

  @spec matches_filter?(map(), map()) :: boolean()
  def matches_filter?(event, filter) when is_map(event) and is_map(filter) do
    case validate_filter(filter) do
      :ok ->
        ids_match?(event, Map.get(filter, "ids")) and
          authors_match?(event, Map.get(filter, "authors")) and
          kinds_match?(event, Map.get(filter, "kinds")) and
          since_match?(event, Map.get(filter, "since")) and
          until_match?(event, Map.get(filter, "until")) and
          tags_match?(event, filter)

      {:error, _reason} ->
        false
    end
  end

  def matches_filter?(_event, _filter), do: false

  @spec error_message(validation_error()) :: String.t()
  def error_message(reason), do: Map.fetch!(@error_messages, reason)

  defp validate_filter_keys(filter) do
    filter
    |> Map.keys()
    |> Enum.reduce_while(:ok, fn key, :ok ->
      if valid_filter_key?(key) do
        {:cont, :ok}
      else
        {:halt, {:error, :invalid_filter_key}}
      end
    end)
  end

  defp valid_filter_key?(key) when is_binary(key) do
    MapSet.member?(@allowed_keys, key) or valid_tag_filter_key?(key)
  end

  defp valid_filter_key?(_key), do: false

  defp valid_tag_filter_key?(<<"#", letter::binary-size(1)>>), do: ascii_letter?(letter)
  defp valid_tag_filter_key?(_key), do: false

  defp ascii_letter?(letter) do
    String.match?(letter, ~r/^[A-Za-z]$/)
  end

  defp validate_hex_filter(nil, _bytes, _error_reason), do: :ok

  defp validate_hex_filter(values, bytes, error_reason) when is_list(values) do
    if values != [] and Enum.all?(values, &lowercase_hex?(&1, bytes)) do
      :ok
    else
      {:error, error_reason}
    end
  end

  defp validate_hex_filter(_values, _bytes, error_reason), do: {:error, error_reason}

  defp validate_kinds(nil), do: :ok

  defp validate_kinds(kinds) when is_list(kinds) do
    if kinds != [] and Enum.all?(kinds, &valid_kind?/1) do
      :ok
    else
      {:error, :invalid_kinds}
    end
  end

  defp validate_kinds(_kinds), do: {:error, :invalid_kinds}

  defp valid_kind?(kind) when is_integer(kind), do: kind >= 0 and kind <= @max_kind
  defp valid_kind?(_kind), do: false

  defp validate_since(nil), do: :ok
  defp validate_since(since) when is_integer(since) and since >= 0, do: :ok
  defp validate_since(_since), do: {:error, :invalid_since}

  defp validate_until(nil), do: :ok
  defp validate_until(until) when is_integer(until) and until >= 0, do: :ok
  defp validate_until(_until), do: {:error, :invalid_until}

  defp validate_limit(nil), do: :ok
  defp validate_limit(limit) when is_integer(limit) and limit > 0, do: :ok
  defp validate_limit(_limit), do: {:error, :invalid_limit}

  defp validate_tag_filters(filter) do
    filter
    |> Enum.filter(fn {key, _value} -> valid_tag_filter_key?(key) end)
    |> Enum.reduce_while(:ok, fn {_key, values}, :ok ->
      if valid_tag_filter_values?(values) do
        {:cont, :ok}
      else
        {:halt, {:error, :invalid_tag_filter}}
      end
    end)
  end

  defp valid_tag_filter_values?(values) when is_list(values) do
    values != [] and Enum.all?(values, &is_binary/1)
  end

  defp valid_tag_filter_values?(_values), do: false

  defp ids_match?(_event, nil), do: true

  defp ids_match?(event, ids) do
    Map.get(event, "id") in ids
  end

  defp authors_match?(_event, nil), do: true

  defp authors_match?(event, authors) do
    Map.get(event, "pubkey") in authors
  end

  defp kinds_match?(_event, nil), do: true

  defp kinds_match?(event, kinds) do
    Map.get(event, "kind") in kinds
  end

  defp since_match?(_event, nil), do: true

  defp since_match?(event, since) do
    created_at = Map.get(event, "created_at")
    is_integer(created_at) and created_at >= since
  end

  defp until_match?(_event, nil), do: true

  defp until_match?(event, until) do
    created_at = Map.get(event, "created_at")
    is_integer(created_at) and created_at <= until
  end

  defp tags_match?(event, filter) do
    filter
    |> Enum.filter(fn {key, _value} -> valid_tag_filter_key?(key) end)
    |> Enum.all?(fn {key, values} ->
      tag_name = String.replace_prefix(key, "#", "")
      tag_values = tag_values_for_name(Map.get(event, "tags"), tag_name)

      Enum.any?(values, &MapSet.member?(tag_values, &1))
    end)
  end

  defp tag_values_for_name(tags, tag_name) when is_list(tags) do
    Enum.reduce(tags, MapSet.new(), fn
      [^tag_name, value | _rest], acc when is_binary(value) ->
        MapSet.put(acc, value)

      _tag, acc ->
        acc
    end)
  end

  defp tag_values_for_name(_tags, _tag_name), do: MapSet.new()

  defp lowercase_hex?(value, bytes) when is_binary(value) do
    byte_size(value) == bytes * 2 and
      match?({:ok, _decoded}, Base.decode16(value, case: :lower))
  end

  defp lowercase_hex?(_value, _bytes), do: false

  defp max_filters_per_req do
    :parrhesia
    |> Application.get_env(:limits, [])
    |> Keyword.get(:max_filters_per_req, @default_max_filters_per_req)
  end
end
