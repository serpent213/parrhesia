defmodule Parrhesia.TestSupport.ExpirationStubEvents do
  @moduledoc false

  @behaviour Parrhesia.Storage.Events

  @impl true
  def put_event(_context, event), do: {:ok, event}

  @impl true
  def get_event(_context, _event_id), do: {:ok, nil}

  @impl true
  def query(_context, _filters, _opts), do: {:ok, []}

  @impl true
  def count(_context, _filters, _opts), do: {:ok, 0}

  @impl true
  def delete_by_request(_context, _event), do: {:ok, 0}

  @impl true
  def vanish(_context, _event), do: {:ok, 0}

  @impl true
  def purge_expired(_opts) do
    test_pid = :persistent_term.get({__MODULE__, :test_pid})
    send(test_pid, :purged)
    {:ok, 0}
  end
end
