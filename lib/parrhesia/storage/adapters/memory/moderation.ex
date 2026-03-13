defmodule Parrhesia.Storage.Adapters.Memory.Moderation do
  @moduledoc """
  In-memory prototype adapter for `Parrhesia.Storage.Moderation`.
  """

  alias Parrhesia.Storage.Adapters.Memory.Store

  @behaviour Parrhesia.Storage.Moderation

  @impl true
  def ban_pubkey(_context, pubkey), do: update_ban_set(:pubkeys, pubkey, :add)

  @impl true
  def unban_pubkey(_context, pubkey), do: update_ban_set(:pubkeys, pubkey, :delete)

  @impl true
  def pubkey_banned?(_context, pubkey), do: {:ok, banned?(:pubkeys, pubkey)}

  @impl true
  def allow_pubkey(_context, pubkey) do
    Store.update(fn state -> update_in(state.allowed_pubkeys, &MapSet.put(&1, pubkey)) end)
    :ok
  end

  @impl true
  def disallow_pubkey(_context, pubkey) do
    Store.update(fn state -> update_in(state.allowed_pubkeys, &MapSet.delete(&1, pubkey)) end)
    :ok
  end

  @impl true
  def pubkey_allowed?(_context, pubkey) do
    {:ok, Store.get(fn state -> MapSet.member?(state.allowed_pubkeys, pubkey) end)}
  end

  @impl true
  def ban_event(_context, event_id), do: update_ban_set(:events, event_id, :add)

  @impl true
  def unban_event(_context, event_id), do: update_ban_set(:events, event_id, :delete)

  @impl true
  def event_banned?(_context, event_id), do: {:ok, banned?(:events, event_id)}

  @impl true
  def block_ip(_context, ip), do: update_ban_set(:ips, ip, :add)

  @impl true
  def unblock_ip(_context, ip), do: update_ban_set(:ips, ip, :delete)

  @impl true
  def ip_blocked?(_context, ip), do: {:ok, banned?(:ips, ip)}

  defp banned?(key, value) do
    Store.get(fn state -> MapSet.member?(state.bans[key], value) end)
  end

  defp update_ban_set(key, value, operation) do
    Store.update(fn state ->
      update_in(state.bans[key], &apply_ban_operation(&1, value, operation))
    end)

    :ok
  end

  defp apply_ban_operation(current, value, :add), do: MapSet.put(current, value)
  defp apply_ban_operation(current, value, :delete), do: MapSet.delete(current, value)
end
