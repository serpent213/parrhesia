defmodule Parrhesia.Storage.Adapters.Postgres.Moderation do
  @moduledoc """
  PostgreSQL-backed implementation for `Parrhesia.Storage.Moderation`.

  Implementation is intentionally staged; callbacks currently return
  `{:error, :not_implemented}` until table design and policy paths land.
  """

  @behaviour Parrhesia.Storage.Moderation

  @impl true
  def ban_pubkey(_context, _pubkey), do: {:error, :not_implemented}

  @impl true
  def unban_pubkey(_context, _pubkey), do: {:error, :not_implemented}

  @impl true
  def pubkey_banned?(_context, _pubkey), do: {:error, :not_implemented}

  @impl true
  def allow_pubkey(_context, _pubkey), do: {:error, :not_implemented}

  @impl true
  def disallow_pubkey(_context, _pubkey), do: {:error, :not_implemented}

  @impl true
  def pubkey_allowed?(_context, _pubkey), do: {:error, :not_implemented}

  @impl true
  def ban_event(_context, _event_id), do: {:error, :not_implemented}

  @impl true
  def unban_event(_context, _event_id), do: {:error, :not_implemented}

  @impl true
  def event_banned?(_context, _event_id), do: {:error, :not_implemented}

  @impl true
  def block_ip(_context, _ip_address), do: {:error, :not_implemented}

  @impl true
  def unblock_ip(_context, _ip_address), do: {:error, :not_implemented}

  @impl true
  def ip_blocked?(_context, _ip_address), do: {:error, :not_implemented}
end
