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
  def query(_context, filters, _opts) do
    with :ok <- Filter.validate_filters(filters) do
      state = Store.get(& &1)

      events =
        state.events
        |> Map.values()
        |> Enum.reject(fn event -> MapSet.member?(state.deleted, event["id"]) end)
        |> Enum.filter(&Filter.matches_any?(&1, filters))

      {:ok, events}
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
    delete_ids =
      event
      |> Map.get("tags", [])
      |> Enum.flat_map(fn
        ["e", event_id | _rest] -> [event_id]
        _tag -> []
      end)

    Store.update(fn state ->
      Enum.reduce(delete_ids, state, fn event_id, acc ->
        update_in(acc.deleted, &MapSet.put(&1, event_id))
      end)
    end)

    {:ok, length(delete_ids)}
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
end
