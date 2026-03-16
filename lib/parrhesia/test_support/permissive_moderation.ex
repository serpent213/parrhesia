defmodule Parrhesia.TestSupport.PermissiveModeration do
  @moduledoc false

  @behaviour Parrhesia.Storage.Moderation

  @impl true
  def ban_pubkey(_context, _pubkey), do: :ok

  @impl true
  def unban_pubkey(_context, _pubkey), do: :ok

  @impl true
  def pubkey_banned?(_context, _pubkey), do: {:ok, false}

  @impl true
  def allow_pubkey(_context, _pubkey), do: :ok

  @impl true
  def disallow_pubkey(_context, _pubkey), do: :ok

  @impl true
  def pubkey_allowed?(_context, _pubkey), do: {:ok, true}

  @impl true
  def has_allowed_pubkeys?(_context), do: {:ok, false}

  @impl true
  def ban_event(_context, _event_id), do: :ok

  @impl true
  def unban_event(_context, _event_id), do: :ok

  @impl true
  def event_banned?(_context, _event_id), do: {:ok, false}

  @impl true
  def block_ip(_context, _ip), do: :ok

  @impl true
  def unblock_ip(_context, _ip), do: :ok

  @impl true
  def ip_blocked?(_context, _ip), do: {:ok, false}
end
