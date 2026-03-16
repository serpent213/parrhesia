defmodule Parrhesia.TestSupport.FailingEvents do
  @moduledoc false

  @behaviour Parrhesia.Storage.Events

  @impl true
  def put_event(_context, _event), do: {:error, :db_down}

  @impl true
  def get_event(_context, _event_id), do: {:error, :db_down}

  @impl true
  def query(_context, _filters, _opts), do: {:error, :db_down}

  @impl true
  def query_event_refs(_context, _filters, _opts), do: {:error, :db_down}

  @impl true
  def count(_context, _filters, _opts), do: {:error, :db_down}

  @impl true
  def delete_by_request(_context, _event), do: {:error, :db_down}

  @impl true
  def vanish(_context, _event), do: {:error, :db_down}

  @impl true
  def purge_expired(_opts), do: {:error, :db_down}
end
