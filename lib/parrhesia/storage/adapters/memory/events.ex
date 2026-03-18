defmodule Parrhesia.Storage.Adapters.Memory.Events do
  @moduledoc """
  In-memory prototype adapter for `Parrhesia.Storage.Events`.
  """

  alias Parrhesia.Protocol.Filter
  alias Parrhesia.Storage.Adapters.Memory.Store

  @behaviour Parrhesia.Storage.Events

  @impl true
  def put_event(_context, event) do
    event_id = Map.fetch!(event, "id")

    case Store.put_event(event_id, event) do
      :ok -> {:ok, event}
      {:error, :duplicate_event} -> {:error, :duplicate_event}
    end
  end

  @impl true
  def get_event(_context, event_id) do
    case Store.get_event(event_id) do
      {:ok, _event, true} -> {:ok, nil}
      {:ok, event, false} -> {:ok, event}
      :error -> {:ok, nil}
    end
  end

  @impl true
  def query(_context, filters, opts) do
    with :ok <- Filter.validate_filters(filters) do
      requester_pubkeys = Keyword.get(opts, :requester_pubkeys, [])

      events =
        filters
        |> Enum.flat_map(&matching_events_for_filter(&1, requester_pubkeys, opts))
        |> deduplicate_events()
        |> sort_events()
        |> maybe_apply_query_limit(opts)

      {:ok, events}
    end
  end

  @impl true
  def query_event_refs(_context, filters, opts) do
    with :ok <- Filter.validate_filters(filters) do
      requester_pubkeys = Keyword.get(opts, :requester_pubkeys, [])

      refs =
        filters
        |> Enum.flat_map(
          &matching_events_for_filter(
            &1,
            requester_pubkeys,
            Keyword.put(opts, :apply_filter_limits?, false)
          )
        )
        |> deduplicate_events()
        |> Enum.map(fn event ->
          %{
            created_at: Map.fetch!(event, "created_at"),
            id: Base.decode16!(Map.fetch!(event, "id"), case: :mixed)
          }
        end)
        |> Enum.sort(&(compare_event_refs(&1, &2) != :gt))
        |> maybe_limit_event_refs(opts)

      {:ok, refs}
    end
  end

  @impl true
  def count(_context, filters, opts) do
    with :ok <- Filter.validate_filters(filters) do
      requester_pubkeys = Keyword.get(opts, :requester_pubkeys, [])

      count =
        filters
        |> Enum.flat_map(
          &matching_events_for_filter(
            &1,
            requester_pubkeys,
            Keyword.put(opts, :apply_filter_limits?, false)
          )
        )
        |> deduplicate_events()
        |> length()

      {:ok, count}
    end
  end

  @impl true
  def delete_by_request(_context, event) do
    deleter_pubkey = Map.get(event, "pubkey")

    delete_event_ids =
      event
      |> Map.get("tags", [])
      |> Enum.flat_map(fn
        ["e", event_id | _rest] when is_binary(event_id) -> [event_id]
        _tag -> []
      end)

    delete_coordinates =
      event
      |> Map.get("tags", [])
      |> Enum.flat_map(fn
        ["a", coordinate | _rest] when is_binary(coordinate) ->
          case parse_delete_coordinate(coordinate) do
            {:ok, parsed_coordinate} -> [parsed_coordinate]
            {:error, _reason} -> []
          end

        _tag ->
          []
      end)

    coordinate_delete_ids =
      Store.reduce_events([], fn candidate, acc ->
        if matches_delete_coordinate?(candidate, delete_coordinates, deleter_pubkey) do
          [candidate["id"] | acc]
        else
          acc
        end
      end)

    all_delete_ids = Enum.uniq(delete_event_ids ++ coordinate_delete_ids)

    Enum.each(all_delete_ids, &Store.mark_deleted/1)

    {:ok, length(all_delete_ids)}
  end

  @impl true
  def vanish(_context, event) do
    pubkey = Map.get(event, "pubkey")

    deleted_ids =
      Store.reduce_events([], fn candidate, acc ->
        if candidate["pubkey"] == pubkey do
          [candidate["id"] | acc]
        else
          acc
        end
      end)

    Enum.each(deleted_ids, &Store.mark_deleted/1)

    {:ok, length(deleted_ids)}
  end

  @impl true
  def purge_expired(_opts), do: {:ok, 0}

  defp parse_delete_coordinate(coordinate) do
    case String.split(coordinate, ":", parts: 3) do
      [kind_part, pubkey, d_tag] ->
        case Integer.parse(kind_part) do
          {kind, ""} when kind >= 0 -> {:ok, %{kind: kind, pubkey: pubkey, d_tag: d_tag}}
          _other -> {:error, :invalid_coordinate}
        end

      _other ->
        {:error, :invalid_coordinate}
    end
  end

  defp matches_delete_coordinate?(candidate, delete_coordinates, deleter_pubkey) do
    Enum.any?(delete_coordinates, fn coordinate ->
      coordinate.pubkey == deleter_pubkey and
        candidate["pubkey"] == deleter_pubkey and
        candidate["kind"] == coordinate.kind and
        coordinate_match_for_kind?(candidate, coordinate)
    end)
  end

  defp coordinate_match_for_kind?(candidate, coordinate) do
    if addressable_kind?(coordinate.kind) do
      candidate_d_tag =
        candidate
        |> Map.get("tags", [])
        |> Enum.find_value("", fn
          ["d", value | _rest] -> value
          _tag -> nil
        end)

      candidate_d_tag == coordinate.d_tag
    else
      replaceable_kind?(coordinate.kind)
    end
  end

  defp replaceable_kind?(kind), do: kind in [0, 3] or (kind >= 10_000 and kind < 20_000)
  defp addressable_kind?(kind), do: kind >= 30_000 and kind < 40_000

  defp giftwrap_visible_to_requester?(%{"kind" => 1059} = event, requester_pubkeys) do
    requester_pubkeys != [] and
      event_targets_any_recipient?(event, requester_pubkeys)
  end

  defp giftwrap_visible_to_requester?(_event, _requester_pubkeys), do: true

  defp event_targets_any_recipient?(event, requester_pubkeys) do
    event
    |> Map.get("tags", [])
    |> Enum.any?(fn
      ["p", recipient | _rest] -> recipient in requester_pubkeys
      _tag -> false
    end)
  end

  defp compare_event_refs(left, right) do
    cond do
      left.created_at < right.created_at -> :lt
      left.created_at > right.created_at -> :gt
      left.id < right.id -> :lt
      left.id > right.id -> :gt
      true -> :eq
    end
  end

  defp maybe_limit_event_refs(refs, opts) do
    case Keyword.get(opts, :limit) do
      limit when is_integer(limit) and limit > 0 -> Enum.take(refs, limit)
      _other -> refs
    end
  end

  defp matching_events_for_filter(filter, requester_pubkeys, opts) do
    cond do
      Map.has_key?(filter, "ids") ->
        direct_id_lookup_events(filter, requester_pubkeys, opts)

      is_tuple(indexed_tag_filter(filter)) ->
        indexed_tag_lookup_events(filter, requester_pubkeys, opts)

      true ->
        scan_filter_matches(filter, requester_pubkeys, opts)
    end
  end

  defp direct_id_lookup_events(filter, requester_pubkeys, opts) do
    filter
    |> Map.get("ids", [])
    |> Enum.reduce([], fn event_id, acc ->
      maybe_prepend_direct_lookup_match(acc, event_id, filter, requester_pubkeys)
    end)
    |> deduplicate_events()
    |> sort_events()
    |> maybe_take_filter_limit(filter, opts)
  end

  defp scan_filter_matches(filter, requester_pubkeys, opts) do
    limit =
      if Keyword.get(opts, :apply_filter_limits?, true) do
        effective_filter_limit(filter, opts)
      else
        nil
      end

    {matches, _count} =
      Store.reduce_events_newest(
        {[], 0},
        &reduce_scan_match(&1, &2, filter, requester_pubkeys, limit)
      )

    matches
    |> Enum.reverse()
    |> sort_events()
  end

  defp indexed_tag_lookup_events(filter, requester_pubkeys, opts) do
    {tag_name, tag_values} = indexed_tag_filter(filter)
    indexed_tag_values = effective_indexed_tag_values(filter, tag_values)

    tag_name
    |> Store.tagged_events(indexed_tag_values)
    |> Enum.filter(&filter_match_visible?(&1, filter, requester_pubkeys))
    |> maybe_take_filter_limit(filter, opts)
  end

  defp indexed_tag_filter(filter) do
    filter
    |> Enum.filter(fn
      {"#" <> _tag_name, values} when is_list(values) -> values != []
      _entry -> false
    end)
    |> Enum.sort_by(fn {key, _values} -> key end)
    |> List.first()
    |> case do
      {"#" <> tag_name, values} -> {tag_name, values}
      nil -> nil
    end
  end

  defp effective_indexed_tag_values(filter, tag_values) do
    case Map.get(filter, "limit") do
      limit when is_integer(limit) and limit == 1 ->
        Enum.take(tag_values, 1)

      _other ->
        tag_values
    end
  end

  defp filter_match_visible?(event, filter, requester_pubkeys) do
    Filter.matches_filter?(event, filter) and
      giftwrap_visible_to_requester?(event, requester_pubkeys)
  end

  defp maybe_prepend_direct_lookup_match(acc, event_id, filter, requester_pubkeys) do
    case Store.get_event(event_id) do
      {:ok, event, false} ->
        if filter_match_visible?(event, filter, requester_pubkeys) do
          [event | acc]
        else
          acc
        end

      _other ->
        acc
    end
  end

  defp reduce_scan_match(event, {acc, count}, filter, requester_pubkeys, limit) do
    if filter_match_visible?(event, filter, requester_pubkeys) do
      maybe_halt_scan([event | acc], count + 1, limit)
    else
      {acc, count}
    end
  end

  defp maybe_halt_scan(acc, count, limit) when is_integer(limit) and count >= limit do
    {:halt, {acc, count}}
  end

  defp maybe_halt_scan(acc, count, _limit), do: {acc, count}

  defp deduplicate_events(events) do
    events
    |> Enum.reduce(%{}, fn event, acc -> Map.put(acc, event["id"], event) end)
    |> Map.values()
  end

  defp sort_events(events) do
    Enum.sort(events, &chronological_sorter/2)
  end

  defp chronological_sorter(left, right) do
    cond do
      left["created_at"] > right["created_at"] -> true
      left["created_at"] < right["created_at"] -> false
      true -> left["id"] < right["id"]
    end
  end

  defp maybe_apply_query_limit(events, opts) do
    case Keyword.get(opts, :limit) do
      limit when is_integer(limit) and limit > 0 -> Enum.take(events, limit)
      _other -> events
    end
  end

  defp maybe_take_filter_limit(events, filter, opts) do
    case effective_filter_limit(filter, opts) do
      limit when is_integer(limit) and limit > 0 -> Enum.take(events, limit)
      _other -> events
    end
  end

  defp effective_filter_limit(filter, opts) do
    max_filter_limit = Keyword.get(opts, :max_filter_limit)

    case Map.get(filter, "limit") do
      limit
      when is_integer(limit) and limit > 0 and is_integer(max_filter_limit) and
             max_filter_limit > 0 ->
        min(limit, max_filter_limit)

      limit when is_integer(limit) and limit > 0 ->
        limit

      _other ->
        nil
    end
  end
end
