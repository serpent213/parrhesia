defmodule Parrhesia.Storage.Adapters.Memory.Store do
  @moduledoc false

  use Agent

  @name __MODULE__
  @events_table :parrhesia_memory_events
  @events_by_time_table :parrhesia_memory_events_by_time
  @events_by_tag_table :parrhesia_memory_events_by_tag
  @events_by_pubkey_table :parrhesia_memory_events_by_pubkey
  @events_by_kind_table :parrhesia_memory_events_by_kind
  @events_by_pubkey_kind_table :parrhesia_memory_events_by_pubkey_kind
  @events_by_address_table :parrhesia_memory_events_by_address

  @initial_state %{
    bans: %{pubkeys: MapSet.new(), events: MapSet.new(), ips: MapSet.new()},
    allowed_pubkeys: MapSet.new(),
    acl_rules: [],
    next_acl_rule_id: 1,
    groups: %{},
    roles: %{},
    audit_logs: []
  }

  def ensure_started, do: start_store()

  def put_event(event_id, event) when is_binary(event_id) and is_map(event) do
    :ok = ensure_started()

    if :ets.insert_new(@events_table, {event_id, event, false}) do
      true = :ets.insert(@events_by_time_table, {{sort_key(event), event_id}, event_id})
      index_event_tags(event_id, event)
      index_event_secondary_keys(event_id, event)
      :ok
    else
      {:error, :duplicate_event}
    end
  end

  def get_event(event_id) when is_binary(event_id) do
    :ok = ensure_started()

    case :ets.lookup(@events_table, event_id) do
      [{^event_id, event, deleted?}] -> {:ok, event, deleted?}
      [] -> :error
    end
  end

  def mark_deleted(event_id) when is_binary(event_id) do
    :ok = ensure_started()

    case lookup_event(event_id) do
      {:ok, event, false} ->
        true = :ets.insert(@events_table, {event_id, event, true})
        true = :ets.delete(@events_by_time_table, {sort_key(event), event_id})
        unindex_event_tags(event_id, event)
        unindex_event_secondary_keys(event_id, event)
        :ok

      {:ok, _event, true} ->
        :ok

      :error ->
        :ok
    end
  end

  def reduce_events(acc, fun) when is_function(fun, 2) do
    :ok = ensure_started()

    :ets.foldl(
      fn {_event_id, event, deleted?}, current_acc ->
        if deleted? do
          current_acc
        else
          fun.(event, current_acc)
        end
      end,
      acc,
      @events_table
    )
  end

  def reduce_events_newest(acc, fun) when is_function(fun, 2) do
    :ok = ensure_started()
    reduce_events_newest_from(:ets.first(@events_by_time_table), acc, fun)
  end

  def tagged_events(tag_name, tag_values) when is_binary(tag_name) and is_list(tag_values) do
    :ok = ensure_started()

    tag_values
    |> Enum.flat_map(&indexed_events_for_value(@events_by_tag_table, {tag_name, &1}))
    |> sort_and_deduplicate_events()
  end

  def events_by_pubkeys(pubkeys) when is_list(pubkeys) do
    :ok = ensure_started()

    pubkeys
    |> Enum.flat_map(&indexed_events_for_value(@events_by_pubkey_table, &1))
    |> sort_and_deduplicate_events()
  end

  def events_by_kinds(kinds) when is_list(kinds) do
    :ok = ensure_started()

    kinds
    |> Enum.flat_map(&indexed_events_for_value(@events_by_kind_table, &1))
    |> sort_and_deduplicate_events()
  end

  def events_by_pubkeys_and_kinds(pubkeys, kinds) when is_list(pubkeys) and is_list(kinds) do
    :ok = ensure_started()

    pubkeys
    |> Enum.flat_map(fn pubkey ->
      kinds
      |> Enum.flat_map(&indexed_events_for_value(@events_by_pubkey_kind_table, {pubkey, &1}))
    end)
    |> sort_and_deduplicate_events()
  end

  def events_by_addresses(addresses) when is_list(addresses) do
    :ok = ensure_started()

    addresses
    |> Enum.flat_map(&indexed_events_for_value(@events_by_address_table, &1))
    |> sort_and_deduplicate_events()
  end

  defp reduce_events_newest_from(:"$end_of_table", acc, _fun), do: acc

  defp reduce_events_newest_from(key, acc, fun) do
    next_key = :ets.next(@events_by_time_table, key)
    acc = reduce_indexed_event(key, acc, fun)

    case acc do
      {:halt, final_acc} -> final_acc
      next_acc -> reduce_events_newest_from(next_key, next_acc, fun)
    end
  end

  defp reduce_indexed_event(key, acc, fun) do
    case :ets.lookup(@events_by_time_table, key) do
      [{^key, event_id}] -> apply_reduce_fun(event_id, acc, fun)
      [] -> acc
    end
  end

  defp apply_reduce_fun(event_id, acc, fun) do
    case lookup_event(event_id) do
      {:ok, event, false} -> normalize_reduce_result(fun.(event, acc))
      _other -> acc
    end
  end

  defp normalize_reduce_result({:halt, next_acc}), do: {:halt, next_acc}
  defp normalize_reduce_result(next_acc), do: next_acc

  def get(fun) do
    :ok = ensure_started()
    Agent.get(@name, fun)
  end

  def update(fun) do
    :ok = ensure_started()
    Agent.update(@name, fun)
  end

  def get_and_update(fun) do
    :ok = ensure_started()
    Agent.get_and_update(@name, fun)
  end

  defp start_store do
    case Agent.start_link(&init_state/0, name: @name) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp init_state do
    ensure_tables_started()

    @initial_state
  end

  defp ensure_tables_started do
    ensure_table(@events_table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    ensure_table(@events_by_time_table, [
      :named_table,
      :public,
      :ordered_set,
      read_concurrency: true,
      write_concurrency: true
    ])

    ensure_table(@events_by_tag_table, [
      :named_table,
      :public,
      :bag,
      read_concurrency: true,
      write_concurrency: true
    ])

    ensure_table(@events_by_pubkey_table, [
      :named_table,
      :public,
      :bag,
      read_concurrency: true,
      write_concurrency: true
    ])

    ensure_table(@events_by_kind_table, [
      :named_table,
      :public,
      :bag,
      read_concurrency: true,
      write_concurrency: true
    ])

    ensure_table(@events_by_pubkey_kind_table, [
      :named_table,
      :public,
      :bag,
      read_concurrency: true,
      write_concurrency: true
    ])

    ensure_table(@events_by_address_table, [
      :named_table,
      :public,
      :bag,
      read_concurrency: true,
      write_concurrency: true
    ])
  end

  defp ensure_table(name, options) do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, options)
      _table -> :ok
    end
  end

  defp lookup_event(event_id) do
    case :ets.lookup(@events_table, event_id) do
      [{^event_id, event, deleted?}] -> {:ok, event, deleted?}
      [] -> :error
    end
  end

  defp index_event_tags(event_id, event) do
    event
    |> event_tag_index_entries(event_id)
    |> Enum.each(fn entry ->
      true = :ets.insert(@events_by_tag_table, entry)
    end)
  end

  defp index_event_secondary_keys(event_id, event) do
    event
    |> secondary_index_entries(event_id)
    |> Enum.each(fn {table, entry} ->
      true = :ets.insert(table, entry)
    end)
  end

  defp unindex_event_tags(event_id, event) do
    event
    |> event_tag_index_entries(event_id)
    |> Enum.each(&:ets.delete_object(@events_by_tag_table, &1))
  end

  defp unindex_event_secondary_keys(event_id, event) do
    event
    |> secondary_index_entries(event_id)
    |> Enum.each(fn {table, entry} ->
      :ets.delete_object(table, entry)
    end)
  end

  defp event_tag_index_entries(event, event_id) do
    created_sort_key = sort_key(event)

    event
    |> Map.get("tags", [])
    |> Enum.flat_map(fn
      [tag_name, tag_value | _rest] when is_binary(tag_name) and is_binary(tag_value) ->
        [{{tag_name, tag_value}, created_sort_key, event_id}]

      _tag ->
        []
    end)
  end

  defp secondary_index_entries(event, event_id) do
    created_sort_key = sort_key(event)
    pubkey = Map.get(event, "pubkey")
    kind = Map.get(event, "kind")

    []
    |> maybe_put_secondary_entry(@events_by_pubkey_table, pubkey, created_sort_key, event_id)
    |> maybe_put_secondary_entry(@events_by_kind_table, kind, created_sort_key, event_id)
    |> maybe_put_pubkey_kind_entry(pubkey, kind, created_sort_key, event_id)
    |> maybe_put_address_entry(event, pubkey, kind, event_id)
  end

  defp maybe_put_secondary_entry(entries, _table, key, _created_sort_key, _event_id)
       when is_nil(key),
       do: entries

  defp maybe_put_secondary_entry(entries, table, key, created_sort_key, event_id) do
    [{table, {key, created_sort_key, event_id}} | entries]
  end

  defp maybe_put_pubkey_kind_entry(entries, pubkey, kind, created_sort_key, event_id)
       when is_binary(pubkey) and is_integer(kind) do
    [{@events_by_pubkey_kind_table, {{pubkey, kind}, created_sort_key, event_id}} | entries]
  end

  defp maybe_put_pubkey_kind_entry(entries, _pubkey, _kind, _created_sort_key, _event_id),
    do: entries

  defp maybe_put_address_entry(entries, event, pubkey, kind, event_id)
       when is_binary(pubkey) and is_integer(kind) and kind >= 30_000 and kind < 40_000 do
    d_tag =
      event
      |> Map.get("tags", [])
      |> Enum.find_value("", fn
        ["d", value | _rest] -> value
        _tag -> nil
      end)

    [{@events_by_address_table, {{kind, pubkey, d_tag}, sort_key(event), event_id}} | entries]
  end

  defp maybe_put_address_entry(entries, _event, _pubkey, _kind, _event_id), do: entries

  defp indexed_events_for_value(_table, value)
       when not is_binary(value) and not is_integer(value) and not is_tuple(value),
       do: []

  defp indexed_events_for_value(table, value) do
    table
    |> :ets.lookup(value)
    |> Enum.reduce([], fn {^value, _created_sort_key, event_id}, acc ->
      case lookup_event(event_id) do
        {:ok, event, false} -> [event | acc]
        _other -> acc
      end
    end)
  end

  defp sort_and_deduplicate_events(events) do
    events
    |> Enum.uniq_by(& &1["id"])
    |> Enum.sort(&chronological_sorter/2)
  end

  defp chronological_sorter(left, right) do
    cond do
      left["created_at"] > right["created_at"] -> true
      left["created_at"] < right["created_at"] -> false
      true -> left["id"] < right["id"]
    end
  end

  defp sort_key(event), do: -Map.get(event, "created_at", 0)
end
