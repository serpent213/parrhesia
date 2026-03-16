defmodule Parrhesia.Storage.Adapters.Postgres.Moderation do
  @moduledoc """
  PostgreSQL-backed implementation for `Parrhesia.Storage.Moderation`.
  """

  import Ecto.Query

  alias Parrhesia.Repo

  @behaviour Parrhesia.Storage.Moderation

  @cache_table :parrhesia_moderation_cache
  @cache_scope_sources %{
    banned_pubkeys: {"banned_pubkeys", :pubkey},
    allowed_pubkeys: {"allowed_pubkeys", :pubkey},
    banned_events: {"banned_events", :event_id},
    blocked_ips: {"blocked_ips", :ip}
  }

  @impl true
  def ban_pubkey(_context, pubkey) do
    with {:ok, normalized_pubkey} <- normalize_hex_or_binary(pubkey, 32, :invalid_pubkey),
         :ok <- upsert_presence_table("banned_pubkeys", :pubkey, normalized_pubkey) do
      cache_put(:banned_pubkeys, normalized_pubkey)
      :ok
    end
  end

  @impl true
  def unban_pubkey(_context, pubkey) do
    with {:ok, normalized_pubkey} <- normalize_hex_or_binary(pubkey, 32, :invalid_pubkey),
         :ok <- delete_from_table("banned_pubkeys", :pubkey, normalized_pubkey) do
      cache_delete(:banned_pubkeys, normalized_pubkey)
      :ok
    end
  end

  @impl true
  def pubkey_banned?(_context, pubkey) do
    with {:ok, normalized_pubkey} <- normalize_hex_or_binary(pubkey, 32, :invalid_pubkey) do
      {:ok, exists_in_scope?(:banned_pubkeys, normalized_pubkey)}
    end
  end

  @impl true
  def allow_pubkey(_context, pubkey) do
    with {:ok, normalized_pubkey} <- normalize_hex_or_binary(pubkey, 32, :invalid_pubkey),
         :ok <- upsert_presence_table("allowed_pubkeys", :pubkey, normalized_pubkey) do
      cache_put(:allowed_pubkeys, normalized_pubkey)
      :ok
    end
  end

  @impl true
  def disallow_pubkey(_context, pubkey) do
    with {:ok, normalized_pubkey} <- normalize_hex_or_binary(pubkey, 32, :invalid_pubkey),
         :ok <- delete_from_table("allowed_pubkeys", :pubkey, normalized_pubkey) do
      cache_delete(:allowed_pubkeys, normalized_pubkey)
      :ok
    end
  end

  @impl true
  def pubkey_allowed?(_context, pubkey) do
    with {:ok, normalized_pubkey} <- normalize_hex_or_binary(pubkey, 32, :invalid_pubkey) do
      {:ok, exists_in_scope?(:allowed_pubkeys, normalized_pubkey)}
    end
  end

  @impl true
  def has_allowed_pubkeys?(_context) do
    {:ok, scope_populated?(:allowed_pubkeys)}
  end

  @impl true
  def ban_event(_context, event_id) do
    with {:ok, normalized_event_id} <- normalize_hex_or_binary(event_id, 32, :invalid_event_id),
         :ok <- upsert_presence_table("banned_events", :event_id, normalized_event_id) do
      cache_put(:banned_events, normalized_event_id)
      :ok
    end
  end

  @impl true
  def unban_event(_context, event_id) do
    with {:ok, normalized_event_id} <- normalize_hex_or_binary(event_id, 32, :invalid_event_id),
         :ok <- delete_from_table("banned_events", :event_id, normalized_event_id) do
      cache_delete(:banned_events, normalized_event_id)
      :ok
    end
  end

  @impl true
  def event_banned?(_context, event_id) do
    with {:ok, normalized_event_id} <- normalize_hex_or_binary(event_id, 32, :invalid_event_id) do
      {:ok, exists_in_scope?(:banned_events, normalized_event_id)}
    end
  end

  @impl true
  def block_ip(_context, ip_address) do
    with {:ok, normalized_ip} <- normalize_ip(ip_address),
         :ok <- upsert_presence_table("blocked_ips", :ip, normalized_ip) do
      cache_put(:blocked_ips, normalized_ip)
      :ok
    end
  end

  @impl true
  def unblock_ip(_context, ip_address) do
    with {:ok, normalized_ip} <- normalize_ip(ip_address),
         :ok <- delete_from_table("blocked_ips", :ip, normalized_ip) do
      cache_delete(:blocked_ips, normalized_ip)
      :ok
    end
  end

  @impl true
  def ip_blocked?(_context, ip_address) do
    with {:ok, normalized_ip} <- normalize_ip(ip_address) do
      {:ok, exists_in_scope?(:blocked_ips, normalized_ip)}
    end
  end

  defp upsert_presence_table(table, field, value) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {inserted, _result} =
      Repo.insert_all(
        table,
        [
          %{
            field => value,
            inserted_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [field]
      )

    if inserted <= 1 do
      :ok
    else
      {:error, :insert_failed}
    end
  end

  defp delete_from_table(table, field, value) do
    query = from(record in table, where: field(record, ^field) == ^value)
    {_deleted, _result} = Repo.delete_all(query)
    :ok
  end

  defp exists_in_scope?(scope, value) do
    {table, field} = cache_scope_source!(scope)

    if moderation_cache_enabled?() do
      case cache_table_ref() do
        :undefined ->
          exists_in_table_db?(table, field, value)

        cache_table ->
          ensure_cache_scope_loaded(scope, cache_table)
          :ets.member(cache_table, cache_member_key(scope, value))
      end
    else
      exists_in_table_db?(table, field, value)
    end
  end

  defp scope_populated?(scope) do
    {table, field} = cache_scope_source!(scope)

    if moderation_cache_enabled?() do
      case cache_table_ref() do
        :undefined ->
          scope_populated_db?(table, field)

        cache_table ->
          ensure_cache_scope_loaded(scope, cache_table)

          :ets.select_count(cache_table, [{{{:member, scope, :_}, true}, [], [true]}]) > 0
      end
    else
      scope_populated_db?(table, field)
    end
  end

  defp ensure_cache_scope_loaded(scope, table) do
    loaded_key = cache_loaded_key(scope)

    if :ets.member(table, loaded_key) do
      :ok
    else
      {db_table, db_field} = cache_scope_source!(scope)
      values = load_scope_values(db_table, db_field)

      entries = Enum.map(values, &{cache_member_key(scope, &1), true})

      if entries != [] do
        true = :ets.insert(table, entries)
      end

      true = :ets.insert(table, {loaded_key, true})
      :ok
    end
  end

  defp load_scope_values(table, field) do
    query =
      from(record in table,
        select: field(record, ^field)
      )

    Repo.all(query)
  end

  defp cache_put(scope, value) do
    if moderation_cache_enabled?() do
      case cache_table_ref() do
        :undefined -> :ok
        cache_table -> true = :ets.insert(cache_table, {cache_member_key(scope, value), true})
      end
    end

    :ok
  end

  defp cache_delete(scope, value) do
    if moderation_cache_enabled?() do
      case cache_table_ref() do
        :undefined -> :ok
        cache_table -> true = :ets.delete(cache_table, cache_member_key(scope, value))
      end
    end

    :ok
  end

  defp cache_scope_source!(scope), do: Map.fetch!(@cache_scope_sources, scope)

  defp cache_loaded_key(scope), do: {:loaded, scope}

  defp cache_member_key(scope, value), do: {:member, scope, value}

  defp cache_table_ref do
    case :ets.whereis(@cache_table) do
      :undefined -> :undefined
      _table_ref -> @cache_table
    end
  end

  defp moderation_cache_enabled? do
    case Application.get_env(:parrhesia, :moderation_cache_enabled, true) do
      true -> true
      false -> false
      _other -> true
    end
  end

  defp exists_in_table_db?(table, field, value) do
    query =
      from(record in table,
        where: field(record, ^field) == ^value,
        select: 1,
        limit: 1
      )

    Repo.one(query) == 1
  end

  defp scope_populated_db?(table, field) do
    query =
      from(record in table,
        select: field(record, ^field),
        limit: 1
      )

    not is_nil(Repo.one(query))
  end

  defp normalize_hex_or_binary(value, expected_bytes, _reason)
       when is_binary(value) and byte_size(value) == expected_bytes,
       do: {:ok, value}

  defp normalize_hex_or_binary(value, expected_bytes, reason) when is_binary(value) do
    if byte_size(value) == expected_bytes * 2 do
      case Base.decode16(value, case: :mixed) do
        {:ok, decoded} -> {:ok, decoded}
        :error -> {:error, reason}
      end
    else
      {:error, reason}
    end
  end

  defp normalize_hex_or_binary(_value, _expected_bytes, reason), do: {:error, reason}

  defp normalize_ip({_, _, _, _} = ip_tuple), do: {:ok, to_inet(ip_tuple)}
  defp normalize_ip({_, _, _, _, _, _, _, _} = ip_tuple), do: {:ok, to_inet(ip_tuple)}

  defp normalize_ip(ip_address) when is_binary(ip_address) do
    ip_address
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, normalized_ip} -> {:ok, to_inet(normalized_ip)}
      {:error, _reason} -> {:error, :invalid_ip_address}
    end
  end

  defp normalize_ip(_ip_address), do: {:error, :invalid_ip_address}

  defp to_inet({_, _, _, _} = ip_tuple), do: %Postgrex.INET{address: ip_tuple, netmask: 32}

  defp to_inet({_, _, _, _, _, _, _, _} = ip_tuple),
    do: %Postgrex.INET{address: ip_tuple, netmask: 128}
end
