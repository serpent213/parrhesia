defmodule Parrhesia.Storage.Moderation do
  @moduledoc """
  Storage callbacks for moderation and access-control state.
  """

  @type context :: map()
  @type pubkey :: binary()
  @type event_id :: binary()
  @type ip_address :: binary()
  @type reason :: term()

  @callback ban_pubkey(context(), pubkey()) :: :ok | {:error, reason()}
  @callback unban_pubkey(context(), pubkey()) :: :ok | {:error, reason()}
  @callback pubkey_banned?(context(), pubkey()) :: {:ok, boolean()} | {:error, reason()}

  @callback allow_pubkey(context(), pubkey()) :: :ok | {:error, reason()}
  @callback disallow_pubkey(context(), pubkey()) :: :ok | {:error, reason()}
  @callback pubkey_allowed?(context(), pubkey()) :: {:ok, boolean()} | {:error, reason()}

  @callback ban_event(context(), event_id()) :: :ok | {:error, reason()}
  @callback unban_event(context(), event_id()) :: :ok | {:error, reason()}
  @callback event_banned?(context(), event_id()) :: {:ok, boolean()} | {:error, reason()}

  @callback block_ip(context(), ip_address()) :: :ok | {:error, reason()}
  @callback unblock_ip(context(), ip_address()) :: :ok | {:error, reason()}
  @callback ip_blocked?(context(), ip_address()) :: {:ok, boolean()} | {:error, reason()}
end
