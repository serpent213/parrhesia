defmodule Parrhesia.Storage.Adapters.Postgres.EventsLifecycleTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Parrhesia.Protocol.EventValidator
  alias Parrhesia.Repo
  alias Parrhesia.Storage.Adapters.Postgres.Events

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "delete_by_request tombstones owned target events" do
    target = event(%{"kind" => 1, "content" => "target"})
    assert {:ok, _event} = Events.put_event(%{}, target)

    delete_request =
      event(%{
        "kind" => 5,
        "tags" => [["e", target["id"]]],
        "content" => "delete"
      })

    assert {:ok, 1} = Events.delete_by_request(%{}, delete_request)
    assert {:ok, nil} = Events.get_event(%{}, target["id"])
  end

  test "delete_by_request tombstones addressable targets referenced via a tags" do
    author = String.duplicate("4", 64)

    target =
      event(%{
        "pubkey" => author,
        "kind" => 30_023,
        "tags" => [["d", "topic"]],
        "content" => "addressable-target"
      })

    assert {:ok, _event} = Events.put_event(%{}, target)

    delete_request =
      event(%{
        "pubkey" => author,
        "kind" => 5,
        "tags" => [["a", "30023:#{author}:topic"]],
        "content" => "delete-addressable"
      })

    assert {:ok, 1} = Events.delete_by_request(%{}, delete_request)
    assert {:ok, nil} = Events.get_event(%{}, target["id"])
  end

  test "vanish hard-deletes events authored by pubkey" do
    author = String.duplicate("3", 64)

    first_event = event(%{"pubkey" => author, "created_at" => 1_700_000_000})
    second_event = event(%{"pubkey" => author, "created_at" => 1_700_000_100})

    assert {:ok, _event} = Events.put_event(%{}, first_event)
    assert {:ok, _event} = Events.put_event(%{}, second_event)

    vanish_event =
      event(%{
        "pubkey" => author,
        "kind" => 62,
        "created_at" => 1_700_000_200,
        "content" => "vanish"
      })

    assert {:ok, count} = Events.vanish(%{}, vanish_event)
    assert count >= 2

    assert {:ok, nil} = Events.get_event(%{}, first_event["id"])
    assert {:ok, nil} = Events.get_event(%{}, second_event["id"])
  end

  defp event(overrides) do
    now = System.system_time(:second)

    base = %{
      "pubkey" => String.duplicate("1", 64),
      "created_at" => now,
      "kind" => 1,
      "tags" => [],
      "content" => "hello",
      "sig" => String.duplicate("2", 128)
    }

    event = Map.merge(base, overrides)
    Map.put(event, "id", EventValidator.compute_id(event))
  end
end
