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

    result =
      Store.get_and_update(fn state ->
        if Map.has_key?(state.events, event_id) do
          {{:error, :duplicate_event}, state}
        else
          next_state = put_in(state.events[event_id], event)
          {{:ok, event}, next_state}
        end
      end)

    result
  end

  @impl true
  def get_event(_context, event_id) do
    deleted? = Store.get(fn state -> MapSet.member?(state.deleted, event_id) end)

    if deleted? do
      {:ok, nil}
    else
      {:ok, Store.get(fn state -> Map.get(state.events, event_id) end)}
    end
  end

  @impl true
  def query(_context, filters, opts) do
    with :ok <- Filter.validate_filters(filters) do
      state = Store.get(& &1)
      requester_pubkeys = Keyword.get(opts, :requester_pubkeys, [])

      events =
        state.events
        |> Map.values()
        |> Enum.filter(fn event ->
          not MapSet.member?(state.deleted, event["id"]) and
            Filter.matches_any?(event, filters) and
            giftwrap_visible_to_requester?(event, requester_pubkeys)
        end)

      {:ok, events}
    end
  end

  @impl true
  def query_event_refs(context, filters, opts) do
    with {:ok, events} <- query(context, filters, opts) do
      refs =
        events
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
  def count(context, filters, opts) do
    with {:ok, events} <- query(context, filters, opts) do
      {:ok, length(events)}
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
      Store.get(fn state ->
        state.events
        |> Map.values()
        |> Enum.filter(fn candidate ->
          matches_delete_coordinate?(candidate, delete_coordinates, deleter_pubkey)
        end)
        |> Enum.map(& &1["id"])
      end)

    all_delete_ids = Enum.uniq(delete_event_ids ++ coordinate_delete_ids)

    Store.update(fn state ->
      Enum.reduce(all_delete_ids, state, fn event_id, acc ->
        update_in(acc.deleted, &MapSet.put(&1, event_id))
      end)
    end)

    {:ok, length(all_delete_ids)}
  end

  @impl true
  def vanish(_context, event) do
    pubkey = Map.get(event, "pubkey")

    deleted_ids =
      Store.get(fn state ->
        state.events
        |> Map.values()
        |> Enum.filter(fn candidate -> candidate["pubkey"] == pubkey end)
        |> Enum.map(& &1["id"])
      end)

    Store.update(fn state ->
      Enum.reduce(deleted_ids, state, fn event_id, acc ->
        update_in(acc.deleted, &MapSet.put(&1, event_id))
      end)
    end)

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
end
