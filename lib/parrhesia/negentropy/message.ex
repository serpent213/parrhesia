defmodule Parrhesia.Negentropy.Message do
  @moduledoc """
  NIP-77 negentropy message codec and helpers.
  """

  import Bitwise

  @protocol_version 0x61
  @id_size 32
  @fingerprint_size 16
  @u256_mod 1 <<< 256
  @zero_id <<0::size(256)>>

  @type item :: %{created_at: non_neg_integer(), id: binary()}
  @type bound :: :infinity | {non_neg_integer(), binary()}
  @type range ::
          %{
            upper_bound: bound(),
            mode: :skip | :fingerprint | :id_list,
            payload: nil | binary() | [binary()]
          }

  @spec protocol_version() :: byte()
  def protocol_version, do: @protocol_version

  @spec supported_version_message() :: binary()
  def supported_version_message, do: <<@protocol_version>>

  @spec decode(binary()) :: {:ok, [range()]} | {:unsupported_version, byte()} | {:error, term()}
  def decode(<<version, _rest::binary>>) when version != @protocol_version,
    do: {:unsupported_version, @protocol_version}

  def decode(<<@protocol_version, rest::binary>>) do
    decode_ranges(rest, 0, initial_lower_bound(), [])
  end

  def decode(_message), do: {:error, :invalid_message}

  @spec encode([range()]) :: binary()
  def encode(ranges) when is_list(ranges) do
    ranges
    |> drop_trailing_skip_ranges()
    |> Enum.reduce({[@protocol_version], 0}, fn range, {acc, previous_timestamp} ->
      {encoded_range, next_timestamp} = encode_range(range, previous_timestamp)
      {[acc, encoded_range], next_timestamp}
    end)
    |> elem(0)
    |> IO.iodata_to_binary()
  end

  @spec fingerprint([item()]) :: binary()
  def fingerprint(items) when is_list(items) do
    sum =
      Enum.reduce(items, 0, fn %{id: id}, acc ->
        <<id_integer::unsigned-little-size(256)>> = id
        rem(acc + id_integer, @u256_mod)
      end)

    payload = [<<sum::unsigned-little-size(256)>>, encode_varint(length(items))]

    payload
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> binary_part(0, @fingerprint_size)
  end

  @spec compare_items(item(), item()) :: :lt | :eq | :gt
  def compare_items(left, right) do
    cond do
      left.created_at < right.created_at -> :lt
      left.created_at > right.created_at -> :gt
      left.id < right.id -> :lt
      left.id > right.id -> :gt
      true -> :eq
    end
  end

  @spec compare_bound(bound(), bound()) :: :lt | :eq | :gt
  def compare_bound(:infinity, :infinity), do: :eq
  def compare_bound(:infinity, _other), do: :gt
  def compare_bound(_other, :infinity), do: :lt

  def compare_bound({left_timestamp, left_id}, {right_timestamp, right_id}) do
    cond do
      left_timestamp < right_timestamp -> :lt
      left_timestamp > right_timestamp -> :gt
      left_id < right_id -> :lt
      left_id > right_id -> :gt
      true -> :eq
    end
  end

  @spec item_in_range?(item(), bound(), bound()) :: boolean()
  def item_in_range?(item, lower_bound, upper_bound) do
    compare_item_to_bound(item, lower_bound) != :lt and
      compare_item_to_bound(item, upper_bound) == :lt
  end

  @spec initial_lower_bound() :: bound()
  def initial_lower_bound, do: {0, @zero_id}

  @spec zero_id() :: binary()
  def zero_id, do: @zero_id

  @spec split_bound(item(), item()) :: bound()
  def split_bound(previous_item, next_item)
      when is_map(previous_item) and is_map(next_item) do
    cond do
      previous_item.created_at < next_item.created_at ->
        {next_item.created_at, @zero_id}

      previous_item.created_at == next_item.created_at ->
        prefix_length = shared_prefix_length(previous_item.id, next_item.id) + 1
        <<prefix::binary-size(prefix_length), _rest::binary>> = next_item.id
        {next_item.created_at, prefix <> :binary.copy(<<0>>, @id_size - prefix_length)}

      true ->
        raise ArgumentError, "split_bound/2 requires previous_item <= next_item"
    end
  end

  defp decode_ranges(<<>>, _previous_timestamp, _lower_bound, ranges),
    do: {:ok, Enum.reverse(ranges)}

  defp decode_ranges(binary, previous_timestamp, lower_bound, ranges) do
    with {:ok, upper_bound, rest, next_timestamp} <- decode_bound(binary, previous_timestamp),
         :ok <- validate_upper_bound(lower_bound, upper_bound),
         {:ok, mode, payload, tail} <- decode_payload(rest) do
      next_ranges = [%{upper_bound: upper_bound, mode: mode, payload: payload} | ranges]

      if upper_bound == :infinity and tail != <<>> do
        {:error, :invalid_message}
      else
        decode_ranges(tail, next_timestamp, upper_bound, next_ranges)
      end
    end
  end

  defp validate_upper_bound(lower_bound, upper_bound) do
    if compare_bound(lower_bound, upper_bound) == :lt do
      :ok
    else
      {:error, :invalid_message}
    end
  end

  defp decode_bound(binary, previous_timestamp) do
    with {:ok, encoded_timestamp, rest} <- decode_varint(binary),
         {:ok, length, tail} <- decode_varint(rest),
         :ok <- validate_bound_prefix_length(length),
         {:ok, prefix, remainder} <- decode_prefix(tail, length) do
      decode_bound_value(encoded_timestamp, length, prefix, remainder, previous_timestamp)
    end
  end

  defp decode_payload(binary) do
    with {:ok, mode_value, rest} <- decode_varint(binary) do
      case mode_value do
        0 ->
          {:ok, :skip, nil, rest}

        1 ->
          decode_fingerprint_payload(rest)

        2 ->
          decode_id_list_payload(rest)

        _other ->
          {:error, :invalid_message}
      end
    end
  end

  defp decode_varint(binary), do: decode_varint(binary, 0)

  defp decode_varint(<<>>, _acc), do: {:error, :invalid_message}

  defp decode_varint(<<byte, rest::binary>>, acc) do
    value = acc * 128 + band(byte, 0x7F)

    if band(byte, 0x80) == 0 do
      {:ok, value, rest}
    else
      decode_varint(rest, value)
    end
  end

  defp encode_range(range, previous_timestamp) do
    {encoded_bound, next_timestamp} = encode_bound(range.upper_bound, previous_timestamp)
    {mode, payload} = encode_payload(range)
    {[encoded_bound, mode, payload], next_timestamp}
  end

  defp encode_bound(:infinity, previous_timestamp),
    do: {[encode_varint(0), encode_varint(0)], previous_timestamp}

  defp encode_bound({timestamp, id}, previous_timestamp) do
    prefix_length = id_prefix_length(id)
    <<prefix::binary-size(prefix_length), _rest::binary>> = id

    {
      [encode_varint(timestamp - previous_timestamp + 1), encode_varint(prefix_length), prefix],
      timestamp
    }
  end

  defp encode_payload(%{mode: :skip}) do
    {encode_varint(0), <<>>}
  end

  defp encode_payload(%{mode: :fingerprint, payload: fingerprint})
       when is_binary(fingerprint) and byte_size(fingerprint) == @fingerprint_size do
    {encode_varint(1), fingerprint}
  end

  defp encode_payload(%{mode: :id_list, payload: ids}) when is_list(ids) do
    encoded_ids = Enum.map(ids, fn id -> validate_id!(id) end)
    {encode_varint(2), [encode_varint(length(encoded_ids)), encoded_ids]}
  end

  defp encode_varint(value) when is_integer(value) and value >= 0 do
    digits = collect_base128_digits(value, [])
    last_index = length(digits) - 1

    digits
    |> Enum.with_index()
    |> Enum.map(fn {digit, index} ->
      if index == last_index do
        digit
      else
        digit + 128
      end
    end)
    |> :erlang.list_to_binary()
  end

  defp collect_base128_digits(value, acc) do
    quotient = div(value, 128)
    remainder = rem(value, 128)

    if quotient == 0 do
      [remainder | acc]
    else
      collect_base128_digits(quotient, [remainder | acc])
    end
  end

  defp unpack_ids(binary), do: unpack_ids(binary, [])

  defp unpack_ids(<<>>, acc), do: Enum.reverse(acc)

  defp unpack_ids(<<id::binary-size(@id_size), rest::binary>>, acc),
    do: unpack_ids(rest, [id | acc])

  defp decode_prefix(binary, length) when byte_size(binary) >= length do
    <<prefix::binary-size(length), rest::binary>> = binary
    {:ok, prefix, rest}
  end

  defp decode_prefix(_binary, _length), do: {:error, :invalid_message}

  defp decode_bound_value(0, 0, _prefix, remainder, previous_timestamp),
    do: {:ok, :infinity, remainder, previous_timestamp}

  defp decode_bound_value(0, _length, _prefix, _remainder, _previous_timestamp),
    do: {:error, :invalid_message}

  defp decode_bound_value(encoded_timestamp, length, prefix, remainder, previous_timestamp) do
    timestamp = previous_timestamp + encoded_timestamp - 1
    id = prefix <> :binary.copy(<<0>>, @id_size - length)
    {:ok, {timestamp, id}, remainder, timestamp}
  end

  defp decode_fingerprint_payload(<<fingerprint::binary-size(@fingerprint_size), tail::binary>>),
    do: {:ok, :fingerprint, fingerprint, tail}

  defp decode_fingerprint_payload(_payload), do: {:error, :invalid_message}

  defp decode_id_list_payload(rest) do
    with {:ok, count, tail} <- decode_varint(rest),
         {:ok, ids, remainder} <- decode_id_list_bytes(tail, count) do
      {:ok, :id_list, ids, remainder}
    end
  end

  defp decode_id_list_bytes(tail, count) do
    expected_bytes = count * @id_size

    if byte_size(tail) >= expected_bytes do
      <<ids::binary-size(expected_bytes), remainder::binary>> = tail
      {:ok, unpack_ids(ids), remainder}
    else
      {:error, :invalid_message}
    end
  end

  defp validate_bound_prefix_length(length)
       when is_integer(length) and length >= 0 and length <= @id_size,
       do: :ok

  defp validate_bound_prefix_length(_length), do: {:error, :invalid_message}

  defp id_prefix_length(id) do
    id
    |> validate_id!()
    |> :binary.bin_to_list()
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == 0))
    |> length()
  end

  defp shared_prefix_length(left_id, right_id) do
    left_id = validate_id!(left_id)
    right_id = validate_id!(right_id)

    left_id
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right_id))
    |> Enum.reduce_while(0, fn
      {left_byte, right_byte}, acc when left_byte == right_byte -> {:cont, acc + 1}
      _pair, acc -> {:halt, acc}
    end)
  end

  defp drop_trailing_skip_ranges(ranges) do
    ranges
    |> Enum.reverse()
    |> Enum.drop_while(fn range -> range.mode == :skip end)
    |> Enum.reverse()
  end

  defp compare_item_to_bound(_item, :infinity), do: :lt

  defp compare_item_to_bound(item, {timestamp, id}) do
    cond do
      item.created_at < timestamp -> :lt
      item.created_at > timestamp -> :gt
      item.id < id -> :lt
      item.id > id -> :gt
      true -> :eq
    end
  end

  defp validate_id!(id) when is_binary(id) and byte_size(id) == @id_size, do: id

  defp validate_id!(_id) do
    raise ArgumentError, "negentropy ids must be 32-byte binaries"
  end
end
