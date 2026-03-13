defmodule Parrhesia.Storage.Adapters.Postgres.Events do
  @moduledoc """
  PostgreSQL-backed implementation for `Parrhesia.Storage.Events`.

  Implementation is intentionally staged; callbacks currently return
  `{:error, :not_implemented}` until migrations and query paths land.
  """

  @behaviour Parrhesia.Storage.Events

  @impl true
  def put_event(_context, _event), do: {:error, :not_implemented}

  @impl true
  def get_event(_context, _event_id), do: {:error, :not_implemented}

  @impl true
  def query(_context, _filters, _opts), do: {:error, :not_implemented}

  @impl true
  def count(_context, _filters, _opts), do: {:error, :not_implemented}

  @impl true
  def delete_by_request(_context, _event), do: {:error, :not_implemented}

  @impl true
  def vanish(_context, _event), do: {:error, :not_implemented}

  @impl true
  def purge_expired(_opts), do: {:error, :not_implemented}
end
