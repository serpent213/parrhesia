defmodule Parrhesia.Tasks.ExpirationWorkerTest do
  use Parrhesia.IntegrationCase, async: false

  alias Parrhesia.Tasks.ExpirationWorker
  alias Parrhesia.TestSupport.ExpirationStubEvents

  setup do
    previous_storage = Application.get_env(:parrhesia, :storage, [])
    :persistent_term.put({ExpirationStubEvents, :test_pid}, self())

    Application.put_env(
      :parrhesia,
      :storage,
      Keyword.put(previous_storage, :events, ExpirationStubEvents)
    )

    on_exit(fn ->
      :persistent_term.erase({ExpirationStubEvents, :test_pid})
      Application.put_env(:parrhesia, :storage, previous_storage)
    end)

    :ok
  end

  test "periodically triggers purge_expired" do
    worker = start_supervised!({ExpirationWorker, name: nil, interval_ms: 10})

    assert is_pid(worker)
    assert_receive :purged
  end
end
