defmodule Parrhesia.Negentropy.Engine do
  @moduledoc """
  Relay/client-agnostic negentropy reconciliation engine.
  """

  alias Parrhesia.Negentropy.Message

  @default_id_list_threshold 32

  @type item :: Message.item()

  @spec initial_message([item()], keyword()) :: binary()
  def initial_message(items, opts \\ []) when is_list(opts) do
    normalized_items = normalize_items(items)

    Message.encode([
      describe_range(normalized_items, :infinity, id_list_threshold(opts))
    ])
  end

  @spec answer([item()], binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def answer(items, incoming_message, opts \\ [])
      when is_binary(incoming_message) and is_list(opts) do
    normalized_items = normalize_items(items)
    threshold = id_list_threshold(opts)

    case Message.decode(incoming_message) do
      {:ok, ranges} ->
        response_ranges =
          respond_to_ranges(normalized_items, ranges, Message.initial_lower_bound(), threshold)

        {:ok, Message.encode(response_ranges)}

      {:unsupported_version, _supported_version} ->
        {:ok, Message.supported_version_message()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp respond_to_ranges(_items, [], _lower_bound, _threshold), do: []

  defp respond_to_ranges(items, [range | rest], lower_bound, threshold) do
    upper_bound = Map.fetch!(range, :upper_bound)

    items_in_range =
      Enum.filter(items, fn item ->
        Message.item_in_range?(item, lower_bound, upper_bound)
      end)

    response =
      case range.mode do
        :skip ->
          [%{upper_bound: upper_bound, mode: :skip, payload: nil}]

        :fingerprint ->
          respond_to_fingerprint_range(items_in_range, upper_bound, range.payload, threshold)

        :id_list ->
          respond_to_id_list_range(items_in_range, upper_bound, range.payload, threshold)
      end

    response ++ respond_to_ranges(items, rest, upper_bound, threshold)
  end

  defp respond_to_fingerprint_range(items, upper_bound, remote_fingerprint, threshold) do
    if Message.fingerprint(items) == remote_fingerprint do
      [%{upper_bound: upper_bound, mode: :skip, payload: nil}]
    else
      mismatch_response(items, upper_bound, threshold)
    end
  end

  defp respond_to_id_list_range(items, upper_bound, remote_ids, threshold) do
    if Enum.map(items, & &1.id) == remote_ids do
      [%{upper_bound: upper_bound, mode: :skip, payload: nil}]
    else
      mismatch_response(items, upper_bound, threshold)
    end
  end

  defp mismatch_response(items, upper_bound, threshold) do
    if length(items) <= threshold do
      [%{upper_bound: upper_bound, mode: :id_list, payload: Enum.map(items, & &1.id)}]
    else
      split_response(items, upper_bound, threshold)
    end
  end

  defp split_response(items, upper_bound, threshold) do
    midpoint = div(length(items), 2)
    left_items = Enum.take(items, midpoint)
    right_items = Enum.drop(items, midpoint)

    boundary =
      left_items
      |> List.last()
      |> then(&Message.split_bound(&1, hd(right_items)))

    [
      describe_range(left_items, boundary, threshold),
      describe_range(right_items, upper_bound, threshold)
    ]
  end

  defp describe_range(items, upper_bound, threshold) do
    if length(items) <= threshold do
      %{upper_bound: upper_bound, mode: :id_list, payload: Enum.map(items, & &1.id)}
    else
      %{upper_bound: upper_bound, mode: :fingerprint, payload: Message.fingerprint(items)}
    end
  end

  defp normalize_items(items) do
    items
    |> Enum.map(&normalize_item/1)
    |> Enum.sort(&(Message.compare_items(&1, &2) != :gt))
  end

  defp normalize_item(%{created_at: created_at, id: id})
       when is_integer(created_at) and created_at >= 0 and is_binary(id) and byte_size(id) == 32 do
    %{created_at: created_at, id: id}
  end

  defp normalize_item(item) do
    raise ArgumentError, "invalid negentropy item: #{inspect(item)}"
  end

  defp id_list_threshold(opts) do
    case Keyword.get(opts, :id_list_threshold, @default_id_list_threshold) do
      threshold when is_integer(threshold) and threshold > 0 -> threshold
      _other -> @default_id_list_threshold
    end
  end
end
