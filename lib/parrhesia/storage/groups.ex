defmodule Parrhesia.Storage.Groups do
  @moduledoc """
  Storage callbacks for NIP-29/NIP-43 group membership and role state.
  """

  @type context :: map()
  @type group_id :: binary()
  @type pubkey :: binary()
  @type membership :: map()
  @type role :: map()
  @type reason :: term()

  @callback put_membership(context(), membership()) :: {:ok, membership()} | {:error, reason()}
  @callback get_membership(context(), group_id(), pubkey()) ::
              {:ok, membership() | nil} | {:error, reason()}
  @callback delete_membership(context(), group_id(), pubkey()) :: :ok | {:error, reason()}
  @callback list_memberships(context(), group_id()) :: {:ok, [membership()]} | {:error, reason()}

  @callback put_role(context(), role()) :: {:ok, role()} | {:error, reason()}
  @callback delete_role(context(), group_id(), pubkey(), binary()) :: :ok | {:error, reason()}
  @callback list_roles(context(), group_id(), pubkey()) :: {:ok, [role()]} | {:error, reason()}
end
