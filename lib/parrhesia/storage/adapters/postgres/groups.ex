defmodule Parrhesia.Storage.Adapters.Postgres.Groups do
  @moduledoc """
  PostgreSQL-backed implementation for `Parrhesia.Storage.Groups`.

  Implementation is intentionally staged; callbacks currently return
  `{:error, :not_implemented}` until group/membership schema lands.
  """

  @behaviour Parrhesia.Storage.Groups

  @impl true
  def put_membership(_context, _membership), do: {:error, :not_implemented}

  @impl true
  def get_membership(_context, _group_id, _pubkey), do: {:error, :not_implemented}

  @impl true
  def delete_membership(_context, _group_id, _pubkey), do: {:error, :not_implemented}

  @impl true
  def list_memberships(_context, _group_id), do: {:error, :not_implemented}

  @impl true
  def put_role(_context, _role), do: {:error, :not_implemented}

  @impl true
  def delete_role(_context, _group_id, _pubkey, _role), do: {:error, :not_implemented}

  @impl true
  def list_roles(_context, _group_id, _pubkey), do: {:error, :not_implemented}
end
